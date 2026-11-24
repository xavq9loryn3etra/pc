#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>

#include "flutter_window.h"
#include "utils.h"

#ifndef _DEBUG
namespace {

// How long a copy may take to show its window (it's shown at its first
// frame) before it counts as stuck.
constexpr ULONGLONG kStuckAfterMs = 20000;

ULONGLONG ProcessAgeMs(HANDLE process) {
  FILETIME created, exited, kernel, user, now;
  if (!::GetProcessTimes(process, &created, &exited, &kernel, &user)) {
    return 0;
  }
  ::GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER from{{created.dwLowDateTime, created.dwHighDateTime}};
  ULARGE_INTEGER to{{now.dwLowDateTime, now.dwHighDateTime}};
  return to.QuadPart > from.QuadPart ? (to.QuadPart - from.QuadPart) / 10000
                                     : 0;
}

// Ours once the other copy has ended (it held [mutex] until then).
bool WaitToOwn(HANDLE mutex, DWORD ms) {
  const DWORD result = ::WaitForSingleObject(mutex, ms);
  return result == WAIT_OBJECT_0 || result == WAIT_ABANDONED;
}

void BringForward(HWND window) {
  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
  ::SetForegroundWindow(window);
}

constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr DWORD kOtherCopyRights =
    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE;

// [pid]'s Popcorn window, shown or not, or null if it has none (yet, or
// any more).
HWND WindowOf(DWORD pid) {
  struct Search {
    DWORD pid;
    HWND found;
  } search{pid, nullptr};
  ::EnumWindows(
      [](HWND window, LPARAM param) -> BOOL {
        auto* s = reinterpret_cast<Search*>(param);
        DWORD owner = 0;
        ::GetWindowThreadProcessId(window, &owner);
        wchar_t name[64];
        if (owner == s->pid && ::GetClassNameW(window, name, 64) &&
            wcscmp(name, kWindowClass) == 0) {
          s->found = window;
          return FALSE;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.found;
}

// The other running Popcorn: the one with a Popcorn window, or else
// (stuck before making its window) another process of this same .exe.
// Null if there's none.
HANDLE FindOtherCopy() {
  if (HWND window = ::FindWindowW(kWindowClass, L"Popcorn")) {
    DWORD pid = 0;
    ::GetWindowThreadProcessId(window, &pid);
    if (pid) return ::OpenProcess(kOtherCopyRights, FALSE, pid);
  }
  wchar_t self[MAX_PATH];
  if (!::GetModuleFileNameW(nullptr, self, MAX_PATH)) return nullptr;
  const wchar_t* self_name = wcsrchr(self, L'\\');
  self_name = self_name ? self_name + 1 : self;
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return nullptr;
  HANDLE found = nullptr;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  for (BOOL more = ::Process32FirstW(snapshot, &entry); more && !found;
       more = ::Process32NextW(snapshot, &entry)) {
    if (entry.th32ProcessID == ::GetCurrentProcessId() ||
        _wcsicmp(entry.szExeFile, self_name) != 0) {
      continue;
    }
    HANDLE process =
        ::OpenProcess(kOtherCopyRights, FALSE, entry.th32ProcessID);
    if (!process) continue;
    wchar_t path[MAX_PATH];
    DWORD size = MAX_PATH;
    if (::QueryFullProcessImageNameW(process, 0, path, &size) &&
        _wcsicmp(path, self) == 0) {
      found = process;
    } else {
      ::CloseHandle(process);
    }
  }
  ::CloseHandle(snapshot);
  return found;
}

// Another Popcorn holds the single-instance [mutex]. Normally its window is
// brought to the front and this launch ends (false). But one that's
// closing (its window gone or going) holds on for a moment: this launch
// waits for it to end and then starts (true) — it used to just end, so
// opening it right after closing it did nothing. And one stuck before its
// first frame keeps a hidden window, or none, for good (owner's PC, 4.6.0,
// 24 Nov 2026: every click after found it and did nothing until it was
// ended in Task Manager): once it's [kStuckAfterMs] old, and has had 10 s
// from this launch to close or show itself, it's ended and this starts.
bool TakeOverFromOtherCopy(HANDLE mutex) {
  HANDLE other = FindOtherCopy();
  if (!other) return WaitToOwn(mutex, 10000);
  const DWORD pid = ::GetProcessId(other);
  const ULONGLONG grace_until = ::GetTickCount64() + 10000;
  for (;;) {
    HWND window = WindowOf(pid);
    if (window && ::IsWindowVisible(window)) {
      BringForward(window);
      // Closing at that very moment (opened again as it was closed)?
      bool going = false;
      for (int i = 0; i < 10 && !going; ++i) {
        going = ::WaitForSingleObject(other, 150) == WAIT_OBJECT_0 ||
                !::IsWindow(window);
      }
      if (!going) {
        ::CloseHandle(other);
        return false;
      }
      continue;  // Its window's gone: wait for it to end, as below.
    }
    if (::WaitForSingleObject(other, 200) == WAIT_OBJECT_0) {
      // Ended: this launch starts in its place.
      ::CloseHandle(other);
      return WaitToOwn(mutex, 5000);
    }
    // No window shown: starting, closing, or stuck.
    if (ProcessAgeMs(other) >= kStuckAfterMs &&
        ::GetTickCount64() >= grace_until) {
      break;
    }
  }
  // Stuck: ended, and this launch starts afresh.
  ::TerminateProcess(other, 1);
  ::WaitForSingleObject(other, 5000);
  ::CloseHandle(other);
  return WaitToOwn(mutex, 5000);
}

}  // namespace
#endif

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
#ifndef _DEBUG
  // One Popcorn at a time: two would each run a torrent engine on the same
  // downloads, and could spoil a half-finished one. Opening it again brings
  // the open window to the front instead. (Not in debug builds, so
  // `flutter run` works beside an installed copy.) The mutex is held until
  // the process ends.
  HANDLE single = ::CreateMutexW(nullptr, TRUE, L"Local\\Popcorn.SingleInstance");
  if (single && ::GetLastError() == ERROR_ALREADY_EXISTS &&
      !TakeOverFromOtherCopy(single)) {
    return EXIT_SUCCESS;
  }
#endif

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Popcorn", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
