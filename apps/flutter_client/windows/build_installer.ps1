param(
    [switch]$SkipFlutterBuild
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$releaseDir = Join-Path $projectDir "build\windows\x64\runner\Release"
$outDir = Join-Path $projectDir "build\windows"
$setupExe = Join-Path $outDir "Popcorn-Setup.exe"
$iconPath = Join-Path $scriptDir "runner\resources\app_icon.ico"

Set-Location $projectDir

# The app's version, from pubspec.yaml ("version: 3.0.0+52" -> 3.0.0), so
# the installer and Windows' Installed apps list show the one being built.
$versionLine = Select-String -Path (Join-Path $projectDir "pubspec.yaml") -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
if (-not $versionLine) { throw "No version: line found in pubspec.yaml" }
$appVersion = $versionLine.Matches[0].Groups[1].Value
Write-Host "Version $appVersion" -ForegroundColor Cyan

if (-not $SkipFlutterBuild) {
    Write-Host "Building Flutter Windows Release..." -ForegroundColor Cyan
    if (Test-Path "secrets.json") {
        flutter build windows --release --dart-define-from-file=secrets.json
    } else {
        flutter build windows --release
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter build failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path (Join-Path $releaseDir "flutter_client.exe"))) {
    throw "Release build not found at $releaseDir\flutter_client.exe"
}

Write-Host "Packaging Release payload..." -ForegroundColor Cyan
$stagingDir = Join-Path $env:TEMP "popcorn_installer_staging_$PID"
$payloadZip = Join-Path $env:TEMP "popcorn_payload_$PID.zip"
$installerCs = Join-Path $env:TEMP "PopcornInstaller_$PID.cs"

try {
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    Copy-Item -Path (Join-Path $releaseDir "*") -Destination $stagingDir -Recurse -Force
    $stagedExe = Join-Path $stagingDir "flutter_client.exe"
    $popcornExe = Join-Path $stagingDir "Popcorn.exe"
    if (Test-Path $stagedExe) {
        Move-Item -Path $stagedExe -Destination $popcornExe -Force
    }
    if (Test-Path $iconPath) {
        Copy-Item -Path $iconPath -Destination (Join-Path $stagingDir "app_icon.ico") -Force
    }

    if (Test-Path $payloadZip) { Remove-Item $payloadZip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingDir,
        $payloadZip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $csCode = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Popcorn Setup")]
[assembly: AssemblyDescription("Popcorn Installer")]
[assembly: AssemblyProduct("Popcorn")]
[assembly: AssemblyVersion("__APP_VERSION__.0")]

namespace PopcornSetup
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length > 0 && args[0] == "--uninstall")
            {
                Uninstall();
                return;
            }
            Application.Run(new InstallerForm());
        }

        static void Uninstall()
        {
            try
            {
                foreach (var p in Process.GetProcessesByName("Popcorn"))
                {
                    try { p.Kill(); p.WaitForExit(3000); } catch { }
                }
                foreach (var p in Process.GetProcessesByName("flutter_client"))
                {
                    try { p.Kill(); p.WaitForExit(3000); } catch { }
                }

                string startMenuLnk = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Programs),
                    "Popcorn.lnk");
                string desktopLnk = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    "Popcorn.lnk");
                if (File.Exists(startMenuLnk)) File.Delete(startMenuLnk);
                if (File.Exists(desktopLnk)) File.Delete(desktopLnk);

                Registry.CurrentUser.DeleteSubKeyTree(
                    @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Popcorn",
                    false);

                MessageBox.Show(
                    "Popcorn shortcuts and registry entries have been removed.",
                    "Popcorn Uninstalled",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Uninstall error: " + ex.Message, "Popcorn", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }

    public class InstallerForm : Form
    {
        private Label statusLabel;
        private ProgressBar progressBar;

        public InstallerForm()
        {
            Text = "Installing Popcorn";
            Size = new Size(420, 160);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(20, 20, 22);
            ForeColor = Color.White;

            try
            {
                Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            }
            catch { }

            statusLabel = new Label
            {
                Text = "Preparing to install Popcorn...",
                AutoSize = false,
                Location = new Point(24, 28),
                Size = new Size(360, 28),
                Font = new Font("Segoe UI", 10.5f, FontStyle.Regular),
                ForeColor = Color.White
            };

            progressBar = new ProgressBar
            {
                Location = new Point(24, 68),
                Size = new Size(356, 22),
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 25
            };

            Controls.Add(statusLabel);
            Controls.Add(progressBar);

            Shown += async (s, e) => await RunInstallAsync();
        }

        private async Task RunInstallAsync()
        {
            try
            {
                string installDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Programs",
                    "Popcorn");

                statusLabel.Text = "Closing running instances...";
                await Task.Run(() =>
                {
                    foreach (var name in new[] { "Popcorn", "flutter_client" })
                    {
                        foreach (var p in Process.GetProcessesByName(name))
                        {
                            try { p.Kill(); p.WaitForExit(4000); } catch { }
                        }
                    }
                });

                statusLabel.Text = "Extracting Popcorn files...";
                await Task.Run(() =>
                {
                    if (Directory.Exists(installDir))
                    {
                        try { Directory.Delete(installDir, true); } catch { }
                    }
                    Directory.CreateDirectory(installDir);

                    using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
                    using (var archive = new ZipArchive(stream, ZipArchiveMode.Read))
                    {
                        foreach (var entry in archive.Entries)
                        {
                            string fullPath = Path.Combine(installDir, entry.FullName);
                            string dir = Path.GetDirectoryName(fullPath);
                            if (!string.IsNullOrEmpty(dir))
                            {
                                Directory.CreateDirectory(dir);
                            }
                            if (!string.IsNullOrEmpty(entry.Name))
                            {
                                entry.ExtractToFile(fullPath, true);
                            }
                        }
                    }
                });

                statusLabel.Text = "Creating Start Menu and Desktop shortcuts...";
                string exePath = Path.Combine(installDir, "Popcorn.exe");
                string iconFile = Path.Combine(installDir, "app_icon.ico");
                if (!File.Exists(iconFile)) iconFile = exePath;

                string startMenuLnk = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Programs),
                    "Popcorn.lnk");
                string desktopLnk = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    "Popcorn.lnk");

                CreateShortcut(startMenuLnk, exePath, installDir, iconFile, "Popcorn");
                CreateShortcut(desktopLnk, exePath, installDir, iconFile, "Popcorn");

                RegisterUninstall(installDir, exePath, iconFile);
                try { SHChangeNotify(0x08000000, 0x0000, IntPtr.Zero, IntPtr.Zero); } catch { }

                statusLabel.Text = "Launching Popcorn...";
                await Task.Delay(350);

                Process.Start(new ProcessStartInfo
                {
                    FileName = exePath,
                    WorkingDirectory = installDir,
                    UseShellExecute = true
                });

                Close();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Failed to install Popcorn:\n" + ex.Message,
                    "Popcorn Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                Close();
            }
        }

        private static void RegisterUninstall(string installDir, string exePath, string iconFile)
        {
            string uninstallerPath = Path.Combine(installDir, "Uninstall-Popcorn.exe");
            try
            {
                File.Copy(Application.ExecutablePath, uninstallerPath, true);
            }
            catch { }

            using (var key = Registry.CurrentUser.CreateSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Popcorn"))
            {
                if (key != null)
                {
                    key.SetValue("DisplayName", "Popcorn");
                    key.SetValue("DisplayIcon", iconFile);
                    key.SetValue("DisplayVersion", "__APP_VERSION__");
                    key.SetValue("Publisher", "Popcorn");
                    key.SetValue("InstallLocation", installDir);
                    key.SetValue("UninstallString", "\"" + uninstallerPath + "\" --uninstall");
                    key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                }
            }
        }

        [DllImport("shell32.dll")]
        private static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);

        private static void CreateShortcut(
            string shortcutPath,
            string targetPath,
            string workingDir,
            string iconPath,
            string description)
        {
            IShellLinkW link = (IShellLinkW)new ShellLink();
            link.SetDescription(description);
            link.SetPath(targetPath);
            link.SetWorkingDirectory(workingDir);
            link.SetIconLocation(iconPath, 0);
            IPersistFile file = (IPersistFile)link;
            file.Save(shortcutPath, false);
        }
    }

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLink
    {
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    internal interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, out IntPtr pfd, int fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, int dwReserved);
        void Resolve(IntPtr hwnd, int fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }
}
'@

    $csCode = $csCode.Replace("__APP_VERSION__", $appVersion)
    Set-Content -Path $installerCs -Value $csCode -Encoding UTF8

    Write-Host "Compiling Popcorn-Setup.exe..." -ForegroundColor Cyan
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

    $cscArgs = @(
        "/nologo",
        "/target:winexe",
        "/optimize+",
        "/out:$setupExe",
        "/r:System.dll",
        "/r:System.Drawing.dll",
        "/r:System.Windows.Forms.dll",
        "/r:System.IO.Compression.dll",
        "/r:System.IO.Compression.FileSystem.dll",
        "/resource:$payloadZip,payload.zip"
    )
    if (Test-Path $iconPath) {
        $cscArgs += "/win32icon:$iconPath"
    }
    $cscArgs += $installerCs

    & $csc @cscArgs
    if ($LASTEXITCODE -ne 0) {
        throw "csc.exe failed with exit code $LASTEXITCODE"
    }

    Write-Host "Successfully built installer: $setupExe" -ForegroundColor Green
}
finally {
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $payloadZip) { Remove-Item $payloadZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path $installerCs) { Remove-Item $installerCs -Force -ErrorAction SilentlyContinue }
}

