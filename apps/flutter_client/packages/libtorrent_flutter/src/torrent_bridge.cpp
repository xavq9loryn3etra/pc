// torrent_bridge.cpp — libtorrent 2.0 streaming engine
// TorrServer-grade streaming: function-by-function C++ port of TorrServer's Go code
// Cross-platform: Windows, Linux, macOS, Android, iOS
//
// Go source mapping:
//   torrstor/ranges.go   → PieceRange, in_ranges(), merge_ranges()
//   torrstor/piece.go    → CachePiece
//   torrstor/mempiece.go → CachePiece (inline memory storage)
//   torrstor/cache.go    → TorrCache
//   torrstor/reader.go   → TorrReader
//   torrstor/storage.go  → integrated into SessionWrapper
//   torr/stream.go       → handle_connection() / serve_range()
//   torr/preload.go      → preload_stream()
//   torr/torrent.go      → StreamEngine lifecycle

#ifdef _WIN32
  #ifndef _WIN32_WINNT
    #define _WIN32_WINNT 0x0601
  #endif
#endif

#include "torrent_bridge.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>

// ── cross-platform sockets ──────────────────────────────────────────────────────
#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #pragma comment(lib, "ws2_32.lib")
  typedef SOCKET socket_t;
  #define SOCKET_INVALID  INVALID_SOCKET
  #define CLOSESOCKET(s)  ::closesocket(s)
  #define INIT_SOCKETS()  { WSADATA _w; ::WSAStartup(MAKEWORD(2,2), &_w); }
  typedef int socklen_t_;
  typedef WSAPOLLFD pollfd_t;
  #define POLL_SOCKETS(f, n, t) ::WSAPoll((f), (ULONG)(n), (t))
  #define POLL_READ_EV    POLLRDNORM
  #define SOCK_ERRNO()    ::WSAGetLastError()
  #define SOCK_EINTR      WSAEINTR
  #define SOCK_EWOULDBLOCK WSAEWOULDBLOCK
#else
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <netinet/tcp.h>
  #include <arpa/inet.h>
  #include <unistd.h>
  #include <fcntl.h>
  #include <signal.h>
  #include <poll.h>
  #include <errno.h>
  typedef int socket_t;
  #define SOCKET_INVALID  (-1)
  #define CLOSESOCKET(s)  ::close(s)
  #define INIT_SOCKETS()  { signal(SIGPIPE, SIG_IGN); }
  typedef socklen_t socklen_t_;
  typedef struct pollfd pollfd_t;
  #define POLL_SOCKETS(f, n, t) ::poll((f), (nfds_t)(n), (t))
  #define POLL_READ_EV    POLLIN
  #define SOCK_ERRNO()    errno
  #define SOCK_EINTR      EINTR
  #define SOCK_EWOULDBLOCK EWOULDBLOCK
#endif

#include <thread>
#include <mutex>
#include <shared_mutex>
#include <condition_variable>
#include <atomic>
#include <unordered_map>
#include <unordered_set>
#include <set>
#include <string>
#include <sstream>
#include <iomanip>
#include <vector>
#include <deque>
#include <memory>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <cinttypes>
#include <functional>
#include <cstdio>
#include <fstream>
#include <filesystem>
#include <iterator>

namespace lt  = libtorrent;
namespace chr = std::chrono;

// ── debug logging ───────────────────────────────────────────────────────────────
// Off in shipped builds. Define TB_DEBUG_LOG (and optionally TB_DEBUG_LOG_PATH)
// at compile time to write a trace file while debugging the engine.
#ifdef TB_DEBUG_LOG
#ifndef TB_DEBUG_LOG_PATH
#define TB_DEBUG_LOG_PATH "torrent_debug.log"
#endif
static FILE* g_logfile = nullptr;
static bool g_log_tried = false;
static std::mutex g_log_mu;

static void tb_log_init() {
    if (!g_logfile && !g_log_tried) {
        g_log_tried = true;
        g_logfile = fopen(TB_DEBUG_LOG_PATH, "w");
        if (g_logfile) {
            setvbuf(g_logfile, nullptr, _IONBF, 0); // unbuffered
        }
    }
}

#define TB_LOG(fmt, ...) do { \
    std::lock_guard<std::mutex> _lk(g_log_mu); \
    tb_log_init(); \
    if (g_logfile) { \
        auto _now = chr::steady_clock::now(); \
        auto _ms = chr::duration_cast<chr::milliseconds>(_now.time_since_epoch()).count() % 100000; \
        fprintf(g_logfile, "[%05lld] " fmt "\n", (long long)_ms, ##__VA_ARGS__); \
    } \
} while(0)
#else
#define TB_LOG(...) ((void)0)
#endif

// ── error handling ──────────────────────────────────────────────────────────────
static thread_local std::string g_last_error;
static void set_err(const std::string& s) { g_last_error = s; }

// ── file extension checks ───────────────────────────────────────────────────────
static bool is_streamable(const std::string& name) {
    static const char* exts[] = {
        ".mkv",".mp4",".avi",".mov",".wmv",".flv",".webm",
        ".m4v",".ts",".m2ts",".mpg",".mpeg",".mp3",".aac",
        ".flac",".opus",".ogg",".wav", nullptr
    };
    auto d = name.rfind('.');
    if (d == std::string::npos) return false;
    std::string e = name.substr(d);
    for (auto& c : e) c = (char)tolower((unsigned char)c);
    for (int i = 0; exts[i]; ++i) if (e == exts[i]) return true;
    return false;
}

// ── port of server/mimetype — MimeTypeByPath ────────────────────────────────────
static std::string get_mime(const std::string& name) {
    auto d = name.rfind('.');
    if (d == std::string::npos) return "video/mp4";
    std::string e = name.substr(d);
    for (auto& c : e) c = (char)tolower((unsigned char)c);
    if (e == ".mkv")  return "video/x-matroska";
    if (e == ".mp4" || e == ".m4v") return "video/mp4";
    if (e == ".avi")  return "video/x-msvideo";
    if (e == ".mov")  return "video/quicktime";
    if (e == ".webm") return "video/webm";
    if (e == ".ts" || e == ".m2ts") return "video/mp2t";
    if (e == ".flv")  return "video/x-flv";
    if (e == ".wmv")  return "video/x-ms-wmv";
    if (e == ".mpg" || e == ".mpeg") return "video/mpeg";
    if (e == ".mp3")  return "audio/mpeg";
    if (e == ".flac") return "audio/flac";
    if (e == ".aac")  return "audio/aac";
    if (e == ".ogg" || e == ".opus") return "audio/ogg";
    if (e == ".wav")  return "audio/wav";
    return "application/octet-stream";
}

// ── resume data: what's downloaded, kept between sessions ──────────────────
// A torrent added again (the app's next launch) used to know nothing of what
// was already on disk: added from its magnet with no resume data, and with
// no_recheck_incomplete_resume set — under which libtorrent 2.0 doesn't even
// look for existing files (mmap_disk_io::do_check_fastresume returns before
// its has_any_file check) — every piece was fetched again, a resumed
// episode waiting on parts already downloaded. Now each torrent's resume
// data (pieces had, and its metadata) is written next to its files,
// ".popcorn-resume-<info hash>", and read back when it's added.

static std::string hash_hex(const lt::info_hash_t& ih) {
    const lt::sha1_hash h = ih.get_best();
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(40);
    for (auto b : h) {
        auto const v = static_cast<unsigned char>(b);
        out.push_back(digits[v >> 4]);
        out.push_back(digits[v & 15]);
    }
    return out;
}

static std::filesystem::path resume_file(const std::string& save_path,
                                         const lt::info_hash_t& ih) {
    return std::filesystem::u8path(save_path)
        / std::filesystem::u8path(".popcorn-resume-" + hash_hex(ih));
}

static lt::info_hash_t hashes_of(const lt::add_torrent_params& p) {
    return p.ti ? p.ti->info_hashes() : p.info_hashes;
}

// Writes [p] (a save_resume_data_alert's) beside the torrent's files —
// through a temporary file, so a crash mid-write leaves the last one whole.
static void write_resume(const lt::add_torrent_params& p) {
    try {
        if (p.save_path.empty()) return;
        const std::vector<char> buf = lt::write_resume_data_buf(p);
        const auto path = resume_file(p.save_path, hashes_of(p));
        auto tmp = path;
        tmp += ".tmp";
        {
            std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
            out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
            if (!out) return;
        }
        std::error_code ec;
        std::filesystem::rename(tmp, path, ec);
    } catch (...) {}
}

// [atp] with the resume data kept for its torrent in [save_path], when
// there is some for it: the pieces had and the metadata (no wait for
// peers to send it), plus [atp]'s trackers. False, and [atp] as it was,
// otherwise.
static bool load_resume(lt::add_torrent_params& atp,
                        const std::string& save_path) {
    try {
        const auto want = hashes_of(atp);
        std::ifstream in(resume_file(save_path, want), std::ios::binary);
        if (!in) return false;
        std::vector<char> buf((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
        if (buf.empty()) return false;
        lt::error_code ec;
        lt::add_torrent_params rd = lt::read_resume_data(buf, ec);
        if (ec || !(hashes_of(rd) == want)) return false;
        for (const auto& t : atp.trackers)
            if (std::find(rd.trackers.begin(), rd.trackers.end(), t)
                    == rd.trackers.end())
                rd.trackers.push_back(t);
        if (!rd.ti && atp.ti) rd.ti = atp.ti;
        rd.save_path = save_path;
        atp = std::move(rd);
        return true;
    } catch (...) {
        return false;
    }
}

// A torrent downloads nothing until a stream asks for pieces
// (lt_start_stream sets them one by one): every file starts at
// dont_download, and priorities kept in its resume data are dropped.
// Before, once metadata came in, every added torrent — each raced warm-up
// copy too, on mobile data as well — downloaded all of its files until the
// app paused it.
static void nothing_wanted_until_streamed(lt::add_torrent_params& atp) {
    atp.file_priorities.clear();
    atp.piece_priorities.clear();
    atp.flags |= lt::torrent_flags::default_dont_download;
}

// ── fill torrent status struct ──────────────────────────────────────────────────
// What fill_status reads: the name and save path (two strings) on top of
// the always-filled fields — not the piece bitfield or the torrent_info,
// which made every 600 ms poll copy them for every torrent.
static const lt::status_flags_t kStatusFlags =
    lt::torrent_handle::query_name | lt::torrent_handle::query_save_path;

static void fill_status(lt_torrent_status& out, int64_t id,
                        const lt::torrent_status& st)
{
    out.id    = id;
    // libtorrent 2.0 numbers its states from 1 (checking_files) with 0
    // unused; the Dart side's from 0 (LT_STATE_*). Casting put every state
    // one off — "finished" for downloading, "seeding" for finished.
    switch (st.state) {
        case lt::torrent_status::checking_files:
            out.state = LT_STATE_CHECKING_FILES; break;
        case lt::torrent_status::downloading_metadata:
            out.state = LT_STATE_DOWNLOADING_META; break;
        case lt::torrent_status::downloading:
            out.state = LT_STATE_DOWNLOADING; break;
        case lt::torrent_status::finished:
            out.state = LT_STATE_FINISHED; break;
        case lt::torrent_status::seeding:
            out.state = LT_STATE_SEEDING; break;
        case lt::torrent_status::checking_resume_data:
            out.state = LT_STATE_CHECKING_RESUME; break;
        default:
            out.state = LT_STATE_UNKNOWN; break;
    }

    if ((st.state == lt::torrent_status::finished ||
         st.state == lt::torrent_status::seeding) && st.progress < 0.999f)
        out.state = LT_STATE_DOWNLOADING;

    out.progress      = st.progress;
    out.download_rate = st.download_rate;
    out.upload_rate   = st.upload_rate;
    out.total_done    = st.total_done;
    out.total_wanted  = st.total_wanted;
    out.total_uploaded = st.total_payload_upload;
    out.num_peers     = st.num_peers;
    out.num_seeds     = st.num_seeds;
    // (libtorrent's num_pieces is the count of pieces had — what the old
    // loop over the piece bitfield counted, without asking for it.)
    out.num_pieces    = (int32_t)st.num_pieces;
    out.pieces_done   = (int32_t)st.num_pieces;

    out.is_paused   = (st.flags & lt::torrent_flags::paused) ? 1 : 0;
    out.is_finished = (st.progress >= 0.999f && st.is_finished) ? 1 : 0;
    out.has_metadata = st.has_metadata ? 1 : 0;

    int qp = static_cast<int>(st.queue_position);
    out.queue_position = (qp < 0) ? -1 : qp;

    // (st.name is the metadata's name once there is metadata.)
    std::strncpy(out.name, st.name.c_str(), sizeof(out.name) - 1);
    out.name[sizeof(out.name) - 1] = 0;

    std::strncpy(out.save_path, st.save_path.c_str(), sizeof(out.save_path) - 1);
    out.save_path[sizeof(out.save_path) - 1] = 0;

    if (st.errc) {
        std::string e = st.errc.message();
        std::strncpy(out.error_msg, e.c_str(), sizeof(out.error_msg) - 1);
        out.error_msg[sizeof(out.error_msg) - 1] = 0;
        out.state = LT_STATE_ERROR;
    } else {
        out.error_msg[0] = 0;
    }
}

// ── read result for async piece reads ───────────────────────────────────────────
struct ReadResult {
    std::vector<char> data;
    bool ok = false;
};

// ── one HTTP request being served ───────────────────────────────────────────────
// Cancelled when a newer playback request on the same stream replaces it
// (see handle_connection), so one connection's seek doesn't end the others.
struct ConnState {
    std::atomic<bool> cancelled{false};
};

// ── alert record for dart queue ─────────────────────────────────────────────────
struct AlertRecord {
    int           type;
    lt_torrent_id torrent_id;
    std::string   message;
};

// ============================================================================
// PORT OF torrstor/ranges.go
// ============================================================================

// Range — port of torrstor.Range
struct PieceRange {
    int     start = 0;
    int     end_  = 0;
    int     file_index = -1;     // which file this range is for
    int64_t file_offset = 0;     // file's byte offset in torrent
    int64_t file_length = 0;     // file's total byte length
};

// inRanges — port of torrstor.inRanges
static bool in_ranges(const std::vector<PieceRange>& ranges, int ind) {
    for (auto& r : ranges) {
        if (ind >= r.start && ind <= r.end_)
            return true;
    }
    return false;
}

// mergeRange — port of torrstor.mergeRange
static std::vector<PieceRange> merge_ranges(std::vector<PieceRange> ranges) {
    if (ranges.size() <= 1) return ranges;

    std::sort(ranges.begin(), ranges.end(), [](const PieceRange& a, const PieceRange& b) {
        if (a.start < b.start) return true;
        if (a.start == b.start && a.end_ < b.end_) return true;
        return false;
    });

    int j = 0;
    for (int i = 1; i < (int)ranges.size(); ++i) {
        if (ranges[j].end_ >= ranges[i].start) {
            if (ranges[j].end_ < ranges[i].end_)
                ranges[j].end_ = ranges[i].end_;
        } else {
            ++j;
            ranges[j] = ranges[i];
        }
    }
    ranges.resize(j + 1);
    return ranges;
}

// ============================================================================
// PORT OF torrstor/piece.go + torrstor/mempiece.go (merged)
// ============================================================================

struct TorrCache; // forward decl

// CachePiece — port of torrstor.Piece + torrstor.MemPiece (memory-only mode)
// Each piece has its own buffer, size tracking, completion flag, access timestamp
struct CachePiece {
    int     id = 0;
    int64_t size = 0;
    bool    complete = false;
    int64_t accessed = 0;   // unix timestamp — port of Piece.Accessed

    std::vector<char> buffer;  // port of MemPiece.buffer
    std::shared_mutex mu;      // port of MemPiece.mu (RWMutex)

    TorrCache* cache = nullptr;

    CachePiece() = default;
    CachePiece(int piece_id, TorrCache* c) : id(piece_id), cache(c) {}

    // port of MemPiece.WriteAt
    int write_at(const char* b, int len, int64_t off);

    // port of MemPiece.ReadAt
    int read_at(char* b, int len, int64_t off);

    // port of Piece.MarkComplete
    void mark_complete() { complete = true; }

    // port of Piece.MarkNotComplete
    void mark_not_complete() { complete = false; }

    // port of MemPiece.Release + Piece.Release
    void release();
};

// ============================================================================
// PORT OF torrstor/reader.go
// ============================================================================

// TorrReader — port of torrstor.Reader
// Tracks a single reader's position, readahead, and active state
struct TorrReader {
    int     reader_id = 0;
    int64_t offset = 0;          // port of Reader.offset
    int64_t readahead = 0;       // port of Reader.readahead
    bool    is_closed = false;   // port of Reader.isClosed
    int64_t last_access = 0;     // port of Reader.lastAccess (unix timestamp)
    bool    is_use = true;       // port of Reader.isUse

    // file info for this reader
    int     file_index = -1;
    int64_t file_offset = 0;     // byte offset of file in torrent
    int64_t file_length = 0;     // file length

    TorrCache* cache = nullptr;
    std::mutex mu;               // port of Reader.mu

    TorrReader() = default;

    // port of Reader.getPieceNum
    int get_piece_num(int64_t off) const;

    // port of Reader.getReaderPiece
    int get_reader_piece() const { return get_piece_num(offset); }

    // port of Reader.getReaderRAHPiece
    int get_reader_rah_piece() const { return get_piece_num(offset + readahead); }

    // port of Reader.getOffsetRange
    void get_offset_range(int64_t& begin_off, int64_t& end_off) const;

    // port of Reader.getPiecesRange
    PieceRange get_pieces_range() const;

    // port of Reader.checkReader — auto-disable idle readers
    void check_reader();

    // port of Reader.readerOn
    void reader_on();

    // port of Reader.readerOff
    void reader_off();

    // port of Reader.getUseReaders
    int get_use_readers() const;

    // port of Reader.SetReadahead
    void set_readahead(int64_t length);

    // port of Reader.Close
    void close();

    static int64_t now_unix() {
        return (int64_t)chr::duration_cast<chr::seconds>(
            chr::system_clock::now().time_since_epoch()).count();
    }
};

// ============================================================================
// PORT OF torrstor/cache.go — the core streaming cache
// ============================================================================

struct TorrCache {
    int64_t capacity = 0;        // port of Cache.capacity (bytes)
    int64_t filled = 0;          // port of Cache.filled
    int64_t piece_length = 0;    // port of Cache.pieceLength
    int     piece_count = 0;     // port of Cache.pieceCount

    std::unordered_map<int, std::unique_ptr<CachePiece>> pieces; // port of Cache.pieces

    std::unordered_map<int, TorrReader*> readers;  // port of Cache.readers (reader_id → reader)
    mutable std::mutex mu_readers;                 // port of Cache.muReaders

    std::atomic<bool> is_remove{false};  // port of Cache.isRemove
    std::atomic<bool> is_closed{false};  // port of Cache.isClosed
    std::mutex mu_remove;                // port of Cache.muRemove

    lt::torrent_handle handle;  // replaces Cache.torrent (anacrolix *torrent.Torrent)

    // TorrServer settings — port of settings.BTsets fields
    int reader_read_ahead_pct = 95;  // port of BTsets.ReaderReadAHead (5-100%)
    int connections_limit = 25;      // port of BTsets.ConnectionsLimit

    // ── port of Cache.Init ──
    void init(int64_t cap, int64_t pl, int pc, const lt::torrent_handle& h) {
        capacity = cap;
        if (capacity == 0) capacity = pl * 4;
        piece_length = pl;
        piece_count = pc;
        handle = h;

        for (int i = 0; i < pc; ++i)
            pieces[i] = std::make_unique<CachePiece>(i, this);
    }

    // ── port of Cache.Piece — get piece by index ──
    CachePiece* get_piece(int index) {
        auto it = pieces.find(index);
        return it != pieces.end() ? it->second.get() : nullptr;
    }

    // ── bounded RAM ──
    // The pieces whose bytes are held in memory, each with when it was last
    // used. Every buffer is filled through store() and freed through drop()
    // or eviction, so held_bytes is what the cache really holds; past
    // max_held_bytes() the least recently used piece goes. Lock order:
    // lru_mu, then a piece's mu.
    std::mutex lru_mu;
    std::unordered_map<int, uint64_t> resident;   // piece → last use tick
    uint64_t lru_tick = 0;
    int64_t  held_bytes = 0;

    int64_t max_held_bytes() const {
        return std::max<int64_t>(4 * piece_length, 64LL * 1024 * 1024);
    }

    // Frees piece [p]'s buffer. Caller holds lru_mu.
    void release_locked(int p) {
        CachePiece* cp = get_piece(p);
        if (!cp) return;
        std::unique_lock<std::shared_mutex> lk(cp->mu);
        held_bytes -= (int64_t)cp->buffer.size();
        if (held_bytes < 0) held_bytes = 0;
        cp->buffer.clear();
        cp->buffer.shrink_to_fit();
        cp->size = 0;
        cp->complete = false;
    }

    // Keeps a copy of piece [p]'s data, evicting the least recently used
    // other pieces while over the cap. False if it couldn't be kept.
    bool store(int p, const char* data, int size) {
        CachePiece* cp = get_piece(p);
        if (!cp || !data || size <= 0 || is_closed.load()) return false;
        std::lock_guard<std::mutex> lk(lru_mu);
        auto it = resident.find(p);
        if (it != resident.end()) { it->second = ++lru_tick; return true; }
        {
            std::unique_lock<std::shared_mutex> plk(cp->mu);
            cp->buffer.assign(data, data + size);
            cp->size = (int64_t)size;
            cp->complete = true;
            cp->accessed = TorrReader::now_unix();
        }
        resident[p] = ++lru_tick;
        held_bytes += (int64_t)size;
        while (held_bytes > max_held_bytes() && resident.size() > 1) {
            auto victim = resident.end();
            for (auto r = resident.begin(); r != resident.end(); ++r) {
                if (r->first == p) continue;
                if (victim == resident.end() || r->second < victim->second)
                    victim = r;
            }
            if (victim == resident.end()) break;
            release_locked(victim->first);
            resident.erase(victim);
        }
        return true;
    }

    // Copies piece [p]'s data into [out] when it's held; false otherwise.
    bool copy_out(int p, std::vector<char>& out) {
        CachePiece* cp = get_piece(p);
        if (!cp) return false;
        {
            std::shared_lock<std::shared_mutex> lk(cp->mu);
            if (cp->buffer.empty() || !cp->complete) return false;
            out.assign(cp->buffer.begin(), cp->buffer.end());
        }
        std::lock_guard<std::mutex> lk(lru_mu);
        auto it = resident.find(p);
        if (it != resident.end()) it->second = ++lru_tick;
        return true;
    }

    bool has(int p) {
        CachePiece* cp = get_piece(p);
        if (!cp) return false;
        std::shared_lock<std::shared_mutex> lk(cp->mu);
        return !cp->buffer.empty() && cp->complete;
    }

    // Frees piece [p]'s buffer, if held.
    void drop(int p) {
        std::lock_guard<std::mutex> lk(lru_mu);
        if (resident.erase(p)) release_locked(p);
    }

    // ── port of Cache.removePiece ──
    void remove_piece(CachePiece* piece) {
        if (!is_closed.load())
            piece->release();
    }

    // ── port of Cache.AdjustRA ──
    void adjust_readahead(int64_t ra) {
        if (capacity == 0) capacity = ra * 3;
        std::lock_guard<std::mutex> lk(mu_readers);
        for (auto& kv : readers) {
            if (kv.second) kv.second->set_readahead(ra);
        }
    }

    // ── port of Cache.cleanPieces ──
    // DISABLED: serve_range handles piece lifecycle directly via
    // libtorrent priorities. Cache eviction would override serve_range's
    // focused priorities and stop downloads.
    void clean_pieces() { return; }

    // ── port of Cache.getRemPieces ──
    std::vector<CachePiece*> get_removable_pieces() {
        std::vector<CachePiece*> pieces_remove;
        int64_t fill = 0;

        // collect ranges from all active readers
        std::vector<PieceRange> ranges;
        {
            std::lock_guard<std::mutex> lk(mu_readers);
            for (auto& kv : readers) {
                auto* r = kv.second;
                if (!r) continue;
                r->check_reader();
                if (r->is_use)
                    ranges.push_back(r->get_pieces_range());
            }
        }
        ranges = merge_ranges(ranges);

        // collect the exact pieces each reader is currently on — NEVER evict these.
        // Also protect the NEXT piece (reader_piece + 1) to prevent a tight
        // evict-download-evict loop at piece boundaries where the reader is
        // about to cross into the next piece.
        std::unordered_set<int> current_reader_pieces;
        {
            std::lock_guard<std::mutex> lk2(mu_readers);
            for (auto& kv2 : readers) {
                auto* r2 = kv2.second;
                if (r2 && r2->is_use) {
                    int rp = r2->get_reader_piece();
                    current_reader_pieces.insert(rp);
                    current_reader_pieces.insert(rp + 1); // protect next piece too
                }
            }
        }

        // find removable pieces — port of the Go loop in getRemPieces
        for (auto& kv : pieces) {
            int id = kv.first;
            auto* p = kv.second.get();
            if (p->size > 0)
                fill += p->size;

            // NEVER evict the piece the reader is currently sitting on
            if (current_reader_pieces.count(id)) continue;

            if (!ranges.empty()) {
                if (!in_ranges(ranges, id)) {
                    if (p->size > 0 && !is_in_file_begin_end(ranges, id))
                        pieces_remove.push_back(p);
                }
            } else {
                // no readers (preload clean mode)
                if (p->size > 0 && !is_in_file_begin_end(ranges, id))
                    pieces_remove.push_back(p);
            }
        }

        clear_priority_impl();
        set_load_priority(ranges);

        // sort by access time — oldest first (LRU). Port of sort.Slice in Go
        std::sort(pieces_remove.begin(), pieces_remove.end(),
            [](const CachePiece* a, const CachePiece* b) {
                return a->accessed < b->accessed;
            });

        filled = fill;
        return pieces_remove;
    }

    // ── port of Cache.setLoadPriority ──
    // DISABLED: serve_range handles all piece prioritization directly
    // with a focused 2-piece-ahead window. The old TorrServer priority
    // gradient (Now/Next/Readahead/High/Normal for 25 pieces) spread
    // bandwidth too thin and conflicted with serve_range's priorities.
    void set_load_priority(const std::vector<PieceRange>& /*ranges*/) { return; }

    // ── port of Cache.isIdInFileBE ──
    // Protects first/last 8-16MB of each file from eviction
    bool is_in_file_begin_end(const std::vector<PieceRange>& ranges, int id) const {
        // keep 8/16 MB — port of FileRangeNotDelete
        int64_t file_range_not_delete = piece_length;
        if (file_range_not_delete < 8 * 1024 * 1024)
            file_range_not_delete = 8 * 1024 * 1024;

        for (auto& rng : ranges) {
            int ss = (int)(rng.file_offset / piece_length);
            int se = (int)((rng.file_offset + file_range_not_delete) / piece_length);
            int es = (int)((rng.file_offset + rng.file_length - file_range_not_delete) / piece_length);
            int ee = (int)((rng.file_offset + rng.file_length) / piece_length);

            if ((id >= ss && id < se) || (id > es && id <= ee))
                return true;
        }
        return false;
    }

    // ── port of Cache.NewReader ──
    TorrReader* new_reader(int reader_id, int file_idx, int64_t file_off, int64_t file_len) {
        auto* r = new TorrReader();
        r->reader_id = reader_id;
        r->file_index = file_idx;
        r->file_offset = file_off;
        r->file_length = file_len;
        r->cache = this;
        r->is_use = true;
        r->set_readahead(0);
        r->last_access = TorrReader::now_unix();

        std::lock_guard<std::mutex> lk(mu_readers);
        readers[reader_id] = r;
        return r;
    }

    // ── port of Cache.GetUseReaders ──
    int get_use_readers() const {
        std::lock_guard<std::mutex> lk(mu_readers);
        int count = 0;
        for (auto& kv : readers)
            if (kv.second && kv.second->is_use) count++;
        return count;
    }

    // ── port of Cache.Readers ──
    int reader_count() const {
        std::lock_guard<std::mutex> lk(mu_readers);
        return (int)readers.size();
    }

    // ── port of Cache.CloseReader ──
    void close_reader(TorrReader* r) {
        if (!r) return;
        if (is_closed.load()) return;  // cache already closed, reader already freed
        try {
            {
                std::lock_guard<std::mutex> lk(mu_readers);
                r->close();
                readers.erase(r->reader_id);
            }
            delete r;
        } catch (...) {
            // Never crash on reader cleanup — reader may already be freed
        }
        // REMOVED: detached thread that called clear_priority_impl() after
        // 1-second delay. When no readers exist (gap between player
        // connections), this set ALL pieces to dont_download, killing
        // all downloads. serve_range handles priorities directly.
    }

    // ── port of Cache.clearPriority ──
    // DISABLED: serve_range handles all piece prioritization directly.
    // The old code set ALL pieces to dont_download when no readers exist,
    // which killed downloads during gaps between player HTTP requests.
    void clear_priority_impl() { return; }

    // ── port of Cache.Close ──
    void close() {
        if (is_closed.load()) return;  // already closed
        is_closed.store(true);
        try {
            std::lock_guard<std::mutex> lk(mu_readers);
            for (auto& kv : readers) {
                try { delete kv.second; } catch (...) {}
            }
            readers.clear();
            pieces.clear();
        } catch (...) {
            // Never crash during cache teardown
        }
    }

    // ── port of Cache.GetCapacity ──
    int64_t get_capacity() const { return capacity; }

    // ── port of Cache.GetState — cache telemetry ──
    void get_state(int64_t& out_capacity, int64_t& out_filled, int& out_pieces_count,
                   int& out_readers) const {
        int64_t fill = 0;
        for (auto& kv : pieces)
            if (kv.second->size > 0) fill += kv.second->size;
        out_capacity = capacity;
        out_filled = fill;
        out_pieces_count = piece_count;
        out_readers = reader_count();
    }
};

// ── CachePiece method implementations (need TorrCache to be defined) ──────────

// port of MemPiece.WriteAt
int CachePiece::write_at(const char* b, int len, int64_t off) {
    std::unique_lock<std::shared_mutex> lk(mu);

    if (buffer.empty()) {
        // clean_pieces call removed — serve_range handles piece lifecycle
        buffer.resize((size_t)cache->piece_length, 0);
    }

    if (off < 0 || (size_t)off >= buffer.size()) return 0;
    int n = std::min(len, (int)(buffer.size() - (size_t)off));
    std::memcpy(buffer.data() + off, b, (size_t)n);
    size += (int64_t)n;
    if (size > cache->piece_length) size = cache->piece_length;
    accessed = TorrReader::now_unix();
    return n;
}

// port of MemPiece.ReadAt
int CachePiece::read_at(char* b, int len, int64_t off) {
    std::shared_lock<std::shared_mutex> lk(mu);

    if (buffer.empty()) return -1; // EOF equivalent

    int avail = (int)buffer.size() - (int)off;
    if (avail <= 0) return -1;
    int n = std::min(len, avail);
    std::memcpy(b, buffer.data() + off, (size_t)n);
    accessed = TorrReader::now_unix();

    // clean_pieces spawn removed — serve_range handles piece lifecycle
    return n;
}

// port of Piece.Release + MemPiece.Release
void CachePiece::release() {
    {
        std::unique_lock<std::shared_mutex> lk(mu);
        buffer.clear();
        buffer.shrink_to_fit();
        size = 0;
        complete = false;
    }
    // REMOVED: setting piece to dont_download. serve_range handles
    // piece lifecycle and priority directly. The old code could nuke
    // pieces that serve_range was actively waiting for.
}

// ── TorrReader method implementations (need TorrCache to be defined) ──────────

// port of Reader.getPieceNum
int TorrReader::get_piece_num(int64_t off) const {
    if (!cache || cache->piece_length <= 0) return 0;
    return (int)((off + file_offset) / cache->piece_length);
}

// port of Reader.getOffsetRange
// 100% forward cache — everything ahead of playback, nothing behind.
// This means even a 64 MB cache can stream a 60 GB file: we only
// keep upcoming data and aggressively evict what's already been played.
void TorrReader::get_offset_range(int64_t& begin_off, int64_t& end_off) const {
    int64_t num_readers = (int64_t)get_use_readers();
    if (num_readers == 0) num_readers = 1;

    begin_off = offset;  // nothing kept behind playback position
    end_off   = offset + (cache->capacity / num_readers);

    if (begin_off < 0) begin_off = 0;
    if (end_off > file_length) end_off = file_length;
}

// port of Reader.getPiecesRange
PieceRange TorrReader::get_pieces_range() const {
    int64_t start_off, end_off;
    get_offset_range(start_off, end_off);
    PieceRange r;
    r.start = get_piece_num(start_off);
    r.end_  = get_piece_num(end_off);
    r.file_index = file_index;
    r.file_offset = file_offset;
    r.file_length = file_length;
    return r;
}

// port of Reader.checkReader — disable idle readers when others exist
void TorrReader::check_reader() {
    if (!cache) return;
    int64_t now = now_unix();
    if (now > last_access + 60 && cache->readers.size() > 1) {
        reader_off();
    } else {
        reader_on();
    }
}

// port of Reader.readerOn
void TorrReader::reader_on() {
    std::lock_guard<std::mutex> lk(mu);
    if (!is_use) {
        is_use = true;
        // readahead is restored in the cache's priority recalculation
    }
}

// port of Reader.readerOff
void TorrReader::reader_off() {
    std::lock_guard<std::mutex> lk(mu);
    if (is_use) {
        readahead = 0;
        is_use = false;
    }
}

// port of Reader.getUseReaders
int TorrReader::get_use_readers() const {
    if (!cache) return 0;
    int count = 0;
    for (auto& kv : cache->readers)
        if (kv.second && kv.second->is_use) count++;
    return count;
}

// port of Reader.SetReadahead
void TorrReader::set_readahead(int64_t length) {
    if (cache && length > cache->capacity)
        length = cache->capacity;
    readahead = length;
}

// port of Reader.Close
void TorrReader::close() {
    is_closed = true;
    // REMOVED: detached thread that called get_removable_pieces()
    // which reset priorities and could nuke pieces serve_range needs.
}

// ============================================================================
// PORT OF torr/stream.go — StreamEngine with TorrCache
// ============================================================================

struct StreamEngine {
    lt_stream_id  id;
    lt_torrent_id torrent_id;
    int           file_index;

    lt::torrent_handle                      handle;
    std::shared_ptr<const lt::torrent_info> ti;

    int64_t file_offset;
    int64_t file_size;
    int     piece_length;
    int     start_piece;
    int     end_piece;
    int     total_pieces;

    // ── TorrServer cache (replaces old piece_cache) ──
    std::unique_ptr<TorrCache> cache;

    // playback
    std::atomic<int64_t> read_head{0};
    std::atomic<int32_t> stream_state{LT_STREAM_BUFFERING};
    std::atomic<int32_t> seek_generation{0};

    // readahead fixed at 16MB like TorrServer — port of torrent.go updateRA()
    static constexpr int64_t FIXED_READAHEAD = 16 * 1024 * 1024;

    // 8MB head/tail for container metadata — port of isIdInFileBE's FileRangeNotDelete
    static constexpr int64_t PROTECT_BYTES = 8 * 1024 * 1024;
    int head_end_piece;
    int tail_start_piece;

    // HTTP server. The listen socket is bound in lt_start_stream and then
    // owned by the server thread, which alone closes it. The server waits
    // in poll() on it and, on POSIX, on a wake pipe; wake_server() makes
    // that poll return (on Windows by connecting to the listen socket).
    std::thread       server_thread;
    socket_t          listen_sock = SOCKET_INVALID;
    int               server_port = 0;
    std::string       url;          // set once in lt_start_stream
#ifndef _WIN32
    int               wake_fds[2] = {-1, -1};
#endif

    // concurrent stream counter — port of stream.go activeStreams
    static std::atomic<int32_t> active_streams;

    // active clients — supports multiple concurrent connections
    // port of TorrServer's multi-reader design
    std::mutex                         clients_mu;
    std::unordered_map<int, std::thread> client_threads;
    std::unordered_map<int, socket_t>    client_sockets;   // track sockets for forced shutdown
    std::unordered_set<int>              finished_clients;  // signal thread completion
    std::atomic<int> next_reader_id{1};

    // The playback request: the latest GET that reads on through the file
    // (not a probe of its tail or a small range). Only it moves read_head
    // and priorities; a new one cancels the one before.
    std::mutex                 conn_mu;
    std::shared_ptr<ConnState> primary;

    // The pieces the playback request has raised since the last seek:
    // [win_lo, win_hi], under win_mu. A seek sets those it leaves behind
    // (not had, not head or tail) back to dont_download.
    std::mutex win_mu;
    int        win_lo = -1;
    int        win_hi = -1;
    int        ra_hi  = -1;   // last piece the read-ahead has raised (win_mu)

    // How far ahead of playback to download: the cache capacity given to
    // lt_start_stream / lt_set_cache_settings, in pieces, 4 to 64.
    std::atomic<int64_t> ra_capacity{64LL * 1024 * 1024};

    int readahead_pieces() const {
        if (piece_length <= 0) return 4;
        const int64_t n = ra_capacity.load() / piece_length;
        return (int)std::clamp<int64_t>(n, 4, 64);
    }

    // Roughly how long playback takes over one piece, in ms.
    int piece_play_ms() const {
        const double ms = (double)piece_length * 1000.0
                        / std::max(1.0f, estimated_bitrate_bps);
        return (int)std::clamp(ms, 50.0, 60000.0);
    }

    void note_window(int lo, int hi) {
        std::lock_guard<std::mutex> lk(win_mu);
        if (win_lo < 0 || lo < win_lo) win_lo = lo;
        if (hi > win_hi) win_hi = hi;
    }

    // In the head or tail kept for the container's headers and index.
    bool is_protected(int p) const {
        return (p >= start_piece && p <= head_end_piece)
            || (p >= tail_start_piece && p <= end_piece);
    }

    // piece availability — signaled by alert thread on piece_finished
    std::mutex              piece_mu;
    std::condition_variable piece_cv;
    std::set<int>           pieces_have;

    // piece data reads — signaled by alert thread on read_piece_alert
    std::mutex              read_mu;
    std::condition_variable read_cv;
    std::unordered_map<int, ReadResult> read_results;

    // preload state — port of torrent.go PreloadSize/PreloadedBytes
    std::atomic<int64_t> preload_size{0};
    std::atomic<int64_t> preloaded_bytes{0};
    std::atomic<bool>    preloading{false};
    std::thread          preload_thread;   // started and joined under preload_mu
    std::mutex           preload_mu;

    // speed tracking — port of torrent.go progressEvent
    std::atomic<double> download_speed{0};
    std::atomic<double> upload_speed{0};

    // trailing retention — keep last N played pieces for re-reads/rewinds
    static constexpr int TRAILING_WINDOW = 3;

    // pieces past a seek target that keep their priority (serve_range's
    // pipeline while waiting)
    static constexpr int SEEK_WINDOW = 16;
    std::deque<int>  trailing_pieces;
    std::mutex       trailing_mu;

    // adaptive bitrate estimate (bytes/sec) — derived from file size
    float estimated_bitrate_bps = 625000.0f;
    int   critical_startup_pieces = 2;  // computed at init

    std::atomic<bool> active{true};

    int byte_to_piece(int64_t off) const {
        if (piece_length <= 0) return start_piece;
        return (int)((file_offset + off) / piece_length);
    }

    void piece_file_range(int p, int64_t& beg, int64_t& end_) const {
        int64_t ps = (int64_t)p * piece_length;
        int64_t pe = ps + piece_length;
        beg  = std::max(ps, file_offset) - file_offset;
        end_ = std::min(pe, file_offset + file_size) - file_offset;
    }

    std::string make_url() const {
        std::string hash = "0000000000000000000000000000000000000000";
        try {
            if (handle.is_valid()) {
                auto ih = handle.info_hashes();
                std::stringstream ss;
                if (ih.has_v1()) {
                    for (auto b : ih.v1)
                        ss << std::hex << std::setw(2) << std::setfill('0') << (int)(uint8_t)b;
                } else if (ih.has_v2()) {
                    for (auto b : ih.v2)
                        ss << std::hex << std::setw(2) << std::setfill('0') << (int)(uint8_t)b;
                }
                hash = ss.str().substr(0, 40);
            }
        } catch (...) {}
        return "http://127.0.0.1:" + std::to_string(server_port)
             + "/stream/" + hash + "/" + std::to_string(file_index);
    }

    // signal piece_finished from alert thread
    void on_piece_finished(int p) {
        TB_LOG("on_piece_finished: piece=%d", p);
        {
            std::lock_guard<std::mutex> lk(piece_mu);
            pieces_have.insert(p);
        }
        // Wake serve_range — it waits on piece_cv for pieces_have
        piece_cv.notify_all();
    }

    // signal read_piece_alert from alert thread
    void on_piece_read(int p, const char* data, int size, bool ok) {
        TB_LOG("on_piece_read: piece=%d ok=%d size=%d", p, (int)ok, size);

        // The data goes into the bounded piece cache — instant re-reads for
        // player probes, overlapping range requests and small backward
        // seeks — and only there: read_piece_data() takes it from the
        // cache. read_results holds just what the cache couldn't (a failed
        // read, or no cache), so nothing is held twice or forever.
        bool cached = false;
        if (ok && data && size > 0 && cache)
            cached = cache->store(p, data, size);

        {
            // (Taken after the cache write, so a waiter that checks the
            // cache under read_mu can't miss it.)
            std::lock_guard<std::mutex> lk(read_mu);
            if (cached) {
                read_results.erase(p);
            } else {
                ReadResult r;
                if (ok && data && size > 0) {
                    r.data.assign(data, data + size);
                    r.ok = true;
                }
                read_results[p] = std::move(r);
            }
        }
        read_cv.notify_all();
    }

    void on_hash_failed(int p) {
        {
            std::lock_guard<std::mutex> lk(piece_mu);
            pieces_have.erase(p);
        }
        if (cache) cache->drop(p);
        try { handle.piece_priority(lt::piece_index_t(p), lt::top_priority); } catch (...) {}
    }

    // Wakes every waiter on piece_cv and read_cv. Each mutex is taken
    // first, so a waiter between checking its predicate and blocking
    // can't miss a flag set before this call.
    void wake_all() {
        { std::lock_guard<std::mutex> lk(piece_mu); }
        piece_cv.notify_all();
        { std::lock_guard<std::mutex> lk(read_mu); }
        read_cv.notify_all();
    }

    // Ends request [c]'s waits: it stops at its next check.
    void cancel(ConnState& c) {
        {
            std::lock_guard<std::mutex> lk(piece_mu);
            c.cancelled = true;
        }
        wake_all();
    }

    // Makes the server thread's poll() return so it sees active == false.
    void wake_server() {
#ifdef _WIN32
        if (server_port <= 0) return;
        socket_t c = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (c == SOCKET_INVALID) return;
        sockaddr_in a{};
        a.sin_family      = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port        = htons((u_short)server_port);
        ::connect(c, (sockaddr*)&a, sizeof(a));
        CLOSESOCKET(c);
#else
        if (wake_fds[1] >= 0) {
            const char b = 1;
            ssize_t n;
            do { n = ::write(wake_fds[1], &b, 1); } while (n < 0 && errno == EINTR);
        }
#endif
    }

    void close_wake_fds() {
#ifndef _WIN32
        for (int& fd : wake_fds) {
            if (fd >= 0) { ::close(fd); fd = -1; }
        }
#endif
    }
};

std::atomic<int32_t> StreamEngine::active_streams{0};

// ── forward declarations ────────────────────────────────────────────────────────
struct SessionWrapper;
static void run_http_server(StreamEngine* stream);

// ── session wrapper ─────────────────────────────────────────────────────────────
struct SessionWrapper {
    lt::session session;

    std::mutex mu;
    std::unordered_map<int64_t, lt::torrent_handle> handles;
    std::unordered_set<int64_t> ephemeral_torrents;
    std::atomic<int64_t> next_id{1};

    std::mutex streams_mu;
    std::unordered_map<int64_t, std::shared_ptr<StreamEngine>> streams;
    std::atomic<int64_t> next_stream_id{1};

    // Stopped streams being torn down on their own threads (see
    // lt_stop_stream); destroy waits for them.
    std::mutex              reap_mu;
    std::condition_variable reap_cv;
    int                     reaping = 0;

    // alert thread — sole consumer of session.pop_alerts()
    std::thread       alert_thread;
    std::atomic<bool> alert_running{false};

    // push callback (called from alert thread)
    lt_alert_callback  dart_callback  = nullptr;
    void*              dart_user_data = nullptr;
    std::mutex         cb_mu;

    // pull queue (for lt_poll_alerts), filled only while someone polls:
    // last_poll_ms is when lt_poll_alerts was last called.
    std::mutex              dart_queue_mu;
    std::deque<AlertRecord> dart_queue;
    std::atomic<int64_t>    last_poll_ms{INT64_MIN / 2};

    static int64_t steady_ms() {
        return (int64_t)chr::duration_cast<chr::milliseconds>(
            chr::steady_clock::now().time_since_epoch()).count();
    }
    bool poll_consumer_active() const {
        return steady_ms() - last_poll_ms.load() < 10000;
    }

    explicit SessionWrapper(lt::session_params params)
        : session(std::move(params)) {}

    // Resume data asked for and not yet written (see request_resume_saves),
    // and when it was last asked for of the torrents that changed.
    std::atomic<int> resume_outstanding{0};
    chr::steady_clock::time_point last_resume_save = chr::steady_clock::now();

    // Asks each torrent with metadata for its resume data — those changed
    // since it was last written, or all ([all], with what's in the disk
    // cache written first): see the save_resume_data_alert in
    // process_alerts. Stream-only torrents aren't kept.
    void request_resume_saves(bool all) {
        std::vector<lt::torrent_handle> hs;
        {
            std::lock_guard<std::mutex> lk(mu);
            for (auto& kv : handles)
                if (!ephemeral_torrents.count(kv.first)) hs.push_back(kv.second);
        }
        for (auto& h : hs) {
            try {
                if (!h.is_valid() || !h.torrent_file()) continue;
                if (!all && !h.need_save_resume_data()) continue;
                resume_outstanding.fetch_add(1);
                h.save_resume_data(all
                    ? (lt::torrent_handle::save_info_dict
                       | lt::torrent_handle::flush_disk_cache)
                    : lt::torrent_handle::save_info_dict);
            } catch (...) {}
        }
    }

    // ── TorrServer config — port of settings.BTSets (session-level defaults) ──
    lt_bt_config bt_config;

    void init_default_config() {
        // port of settings.SetDefaultConfig()
        bt_config.cache_size = 64 * 1024 * 1024;       // 64 MB
        bt_config.reader_read_ahead = 95;               // 95%
        bt_config.preload_cache = 50;                   // 50%
        bt_config.connections_limit = 25;
        bt_config.torrent_disconnect_timeout = 30;      // 30 seconds
        bt_config.force_encrypt = 0;                    // pe_enabled
        bt_config.disable_tcp = 0;
        bt_config.disable_utp = 0;
        bt_config.disable_upload = 0;
        bt_config.disable_dht = 0;
        bt_config.disable_upnp = 0;
        bt_config.enable_ipv6 = 0;
        bt_config.download_rate_limit = 0;              // unlimited
        bt_config.upload_rate_limit = 0;                // unlimited
        bt_config.peers_listen_port = 0;                // random
        bt_config.responsive_mode = 1;                  // enabled by default
    }

    int64_t id_for_handle(const lt::torrent_handle& h) {
        std::lock_guard<std::mutex> lk(mu);
        for (auto& kv : handles)
            if (kv.second == h) return kv.first;
        return -1;
    }

    void start_alert_thread() {
        alert_running = true;
        alert_thread = std::thread([this]() { process_alerts(); });
    }

    void process_alerts() {
        while (alert_running.load()) {
            try {
                // Every 30 s, the resume data of torrents that changed: the
                // app is often closed without the session being destroyed.
                const auto now = chr::steady_clock::now();
                if (now - last_resume_save > chr::seconds(30)) {
                    last_resume_save = now;
                    request_resume_saves(false);
                }
                if (!session.wait_for_alert(lt::milliseconds(100)))
                    continue;
                std::vector<lt::alert*> alerts;
                session.pop_alerts(&alerts);

                for (auto* a : alerts) {
                    if (!a) continue;
                    try {
                        // read_piece_alert → route to stream's cache
                        if (auto* rpa = lt::alert_cast<lt::read_piece_alert>(a)) {
                            int p = static_cast<int>(rpa->piece);
                            std::lock_guard<std::mutex> slk(streams_mu);
                            for (auto& kv : streams) {
                                auto& s = kv.second;
                                if (!s->active || s->handle != rpa->handle) continue;
                                s->on_piece_read(p,
                                    rpa->error ? nullptr : rpa->buffer.get(),
                                    rpa->error ? 0 : rpa->size,
                                    !rpa->error);
                                break;
                            }
                            continue;
                        }

                        // piece_finished_alert → signal waiters + update cache
                        if (auto* pfa = lt::alert_cast<lt::piece_finished_alert>(a)) {
                            int p = static_cast<int>(pfa->piece_index);
                            std::lock_guard<std::mutex> slk(streams_mu);
                            for (auto& kv : streams) {
                                auto& s = kv.second;
                                if (!s->active || s->handle != pfa->handle) continue;
                                if (p >= s->start_piece && p <= s->end_piece)
                                    s->on_piece_finished(p);
                                break;
                            }
                        }

                        // hash_failed_alert → remove from available, re-request
                        else if (auto* hf = lt::alert_cast<lt::hash_failed_alert>(a)) {
                            int p = static_cast<int>(hf->piece_index);
                            std::lock_guard<std::mutex> slk(streams_mu);
                            for (auto& kv : streams) {
                                auto& s = kv.second;
                                if (!s->active || s->handle != hf->handle) continue;
                                if (p >= s->start_piece && p <= s->end_piece)
                                    s->on_hash_failed(p);
                                break;
                            }
                        }

                        // resume data → written beside the torrent's files
                        else if (auto* sra = lt::alert_cast<lt::save_resume_data_alert>(a)) {
                            write_resume(sra->params);
                            if (resume_outstanding.load() > 0)
                                resume_outstanding.fetch_sub(1);
                        }
                        else if (lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
                            if (resume_outstanding.load() > 0)
                                resume_outstanding.fetch_sub(1);
                        }

                        // metadata_received → pause and zero-out file priorities (stream-only)
                        else if (auto* mra = lt::alert_cast<lt::metadata_received_alert>(a)) {
                            int64_t mid = id_for_handle(mra->handle);
                            bool is_ephemeral = false;
                            {
                                std::lock_guard<std::mutex> lk(mu);
                                is_ephemeral = ephemeral_torrents.count(mid) > 0;
                            }
                            if (is_ephemeral) {
                                try {
                                    auto ti = mra->handle.torrent_file();
                                    if (ti) {
                                        int nf = ti->files().num_files();
                                        std::vector<lt::download_priority_t> p(
                                            (size_t)nf, lt::dont_download);
                                        mra->handle.prioritize_files(p);
                                        mra->handle.pause();
                                    }
                                } catch (...) {}
                            }
                        }

                        // Pass the alert on — only when something takes it:
                        // a callback set with lt_set_alert_callback, or a
                        // caller of lt_poll_alerts in the last 10 s. Nobody
                        // listening, no message formatting and no queue.
                        bool want_cb;
                        {
                            std::lock_guard<std::mutex> cl(cb_mu);
                            want_cb = dart_callback != nullptr;
                        }
                        const bool want_queue = poll_consumer_active();
                        if (!want_cb && !want_queue) continue;

                        lt_torrent_id tid = -1;
                        if (auto* ta = dynamic_cast<lt::torrent_alert*>(a))
                            tid = id_for_handle(ta->handle);
                        const std::string msg = a->message();

                        if (want_queue) {
                            std::lock_guard<std::mutex> ql(dart_queue_mu);
                            if (dart_queue.size() < 2048)
                                dart_queue.push_back({a->type(), tid, msg});
                        }

                        if (want_cb) {
                            std::lock_guard<std::mutex> cl(cb_mu);
                            if (dart_callback)
                                dart_callback(a->type(), tid, msg.c_str(), dart_user_data);
                        }
                    } catch (...) {}
                }

                // TorrServer recalculates priorities on every piece event via
                // cleanPieces → getRemPieces → setLoadPriority. Our alert thread
                // already marks pieces complete which triggers cleanPieces via
                // the cache write path.

            } catch (...) {}
        }
    }
};

static SessionWrapper* to_sw(lt_session_t h) {
    return reinterpret_cast<SessionWrapper*>(h);
}

// ── stream shutdown ─────────────────────────────────────────────────────────────
// Tells stream [s]'s threads to stop and wakes every wait. Cheap; never blocks.
static void begin_shutdown(StreamEngine* s) {
    {
        std::lock_guard<std::mutex> lk(s->piece_mu);
        s->active = false;
    }
    s->preloading.store(false);
    s->wake_all();
}

// Waits for [s]'s threads (preload, server, and the server's clients) and
// frees its cache. Blocks — never on the UI thread.
static void finish_shutdown(StreamEngine* s) {
    s->wake_server();
    {
        // (lt_preload_stream starts the thread under preload_mu, and only
        // while active: none can start after this.)
        std::lock_guard<std::mutex> lk(s->preload_mu);
        if (s->preload_thread.joinable()) s->preload_thread.join();
    }
    // server_thread joins all client threads before returning, and must
    // finish before cache->close(): client threads use TorrReader objects
    // owned by the cache.
    if (s->server_thread.joinable()) s->server_thread.join();
    if (s->cache) s->cache->close();
    s->close_wake_fds();
}

// ── piece waiting — port of blocking read in TorrServer's Reader.Read ────────
// blocks until piece is downloaded and verified — zero CPU polling

// Whether libtorrent has [piece], asked directly — recorded in pieces_have
// if so. For a wait that timed out: a piece_finished_alert can be missed
// (e.g. one for a piece that finished just as the stream started), and
// without this the wait would never end.
static bool check_have(StreamEngine* s, int piece) {
    bool h = false;
    try { h = s->handle.have_piece(lt::piece_index_t(piece)); } catch (...) {}
    if (h) {
        {
            std::lock_guard<std::mutex> lk(s->piece_mu);
            s->pieces_have.insert(piece);
        }
        s->piece_cv.notify_all();
    }
    return h;
}

static bool wait_for_piece(StreamEngine* s, int piece, int timeout_ms,
                           int gen = -1) {
    if (gen < 0) gen = s->seek_generation.load();
    std::unique_lock<std::mutex> lk(s->piece_mu);
    if (s->pieces_have.count(piece)) return true;

    // deadline + top priority — triggers time-critical download from multiple peers
    try {
        s->handle.set_piece_deadline(lt::piece_index_t(piece), 0);
        s->handle.piece_priority(lt::piece_index_t(piece), lt::top_priority);
    } catch (...) {}

    s->piece_cv.wait_for(lk, chr::milliseconds(timeout_ms),
        [&]{ return !s->active.load()
                 || s->seek_generation.load() != gen
                 || s->pieces_have.count(piece) > 0; });
    if (s->pieces_have.count(piece) > 0) return true;
    if (!s->active.load() || s->seek_generation.load() != gen) return false;
    lk.unlock();
    return check_have(s, piece);
}

// Read piece data directly from libtorrent disk storage.
// Like lt2http: storage()->readv() — reads downloaded piece data.
static ReadResult read_piece_data(StreamEngine* s, const ConnState& conn,
                                  int piece, int timeout_ms = 5000) {
    auto stopped = [&] {
        return !s->active.load() || conn.cancelled.load();
    };

    // Check hot piece cache first — instant for re-reads
    ReadResult r;
    if (s->cache && s->cache->copy_out(piece, r.data)) { r.ok = true; return r; }

    // Check if we already have a read result buffered
    {
        std::lock_guard<std::mutex> lk(s->read_mu);
        auto it = s->read_results.find(piece);
        if (it != s->read_results.end() && it->second.ok) {
            r = std::move(it->second);
            s->read_results.erase(it);
            return r;
        }
        s->read_results.erase(piece);
    }

    // Ask libtorrent to read the piece from disk, and wait for it to land
    // in the cache (or in read_results). Asked again every 2 s: the cache
    // may have evicted it before we looked, or a stale failed read may
    // have answered first.
    const auto deadline = chr::steady_clock::now() + chr::milliseconds(timeout_ms);
    int failures = 0;
    for (;;) {
        try { s->handle.read_piece(lt::piece_index_t(piece)); } catch (...) {
            return {};
        }
        const auto now = chr::steady_clock::now();
        if (now >= deadline) return {};
        const auto slice = std::min<chr::steady_clock::duration>(
            deadline - now, chr::seconds(2));

        std::unique_lock<std::mutex> lk(s->read_mu);
        s->read_cv.wait_for(lk, slice, [&] {
            return stopped()
                || s->read_results.count(piece) > 0
                || (s->cache && s->cache->has(piece));
        });
        if (stopped()) return {};
        auto it = s->read_results.find(piece);
        if (it != s->read_results.end()) {
            r = std::move(it->second);
            s->read_results.erase(it);
            if (r.ok) return r;
            if (++failures >= 3) return {};
            continue;
        }
        lk.unlock();
        if (s->cache && s->cache->copy_out(piece, r.data)) { r.ok = true; return r; }
    }
}

// ── HTTP server — port of torr/stream.go Stream() ───────────────────────────

struct RangeReq {
    int64_t start = -1;
    int64_t end   = -1;
    bool    valid = false;
};

static RangeReq parse_range(const char* buf, int len) {
    RangeReq r;
    std::string s(buf, (size_t)len);
    std::string sl = s;
    for (auto& c : sl) c = (char)tolower((unsigned char)c);

    auto pos = sl.find("range: bytes=");
    if (pos == std::string::npos) return r;

    r.valid = true;
    pos += 13;
    auto end = s.find('\r', pos);
    if (end == std::string::npos) end = s.size();
    std::string rs = s.substr(pos, end - pos);
    auto dash = rs.find('-');
    if (dash != std::string::npos) {
        try {
            if (dash > 0) r.start = std::stoll(rs.substr(0, dash));
            if (dash + 1 < rs.size()) r.end = std::stoll(rs.substr(dash + 1));
        } catch (...) {}
    }
    return r;
}

// Whether the HTTP client has gone — closed its end, or the socket failed.
// Never blocks.
static bool client_gone(socket_t cli) {
    pollfd_t pfd{};
    pfd.fd     = cli;
    pfd.events = POLL_READ_EV;
    int r = POLL_SOCKETS(&pfd, 1, 0);
    if (r < 0) return SOCK_ERRNO() != SOCK_EINTR;
    if (r == 0) return false;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return true;
    if (pfd.revents & POLL_READ_EV) {
        char b;
        int n = ::recv(cli, &b, 1, MSG_PEEK);  // readable: doesn't block
        if (n == 0) return true;                // orderly close
        if (n < 0) {
            int e = SOCK_ERRNO();
            return e != SOCK_EINTR && e != SOCK_EWOULDBLOCK;
        }
    }
    return false;
}

static int send_all(socket_t sock, const char* data, int len) {
    int sent = 0;
    while (sent < len) {
        int n = ::send(sock, data + sent, len - sent, 0);
        if (n <= 0) return -1;
        sent += n;
    }
    return sent;
}

// Read-ahead, run after the playback request sends piece [p]: pieces
// (p, p+N] are kept wanted — the next two at top priority, the rest at 6 —
// with deadlines spaced by the time playback takes to reach them, N being
// readahead_pieces(). Before, pieces ahead were raised only while the
// reader was blocked on one, so the download never got ahead of playback.
// When N shrinks (the cache cut down in the background), the pieces past
// the new end go back to dont_download.
static void extend_readahead(StreamEngine* s, int p) {
    const int n  = s->readahead_pieces();
    const int hi = std::min(p + n, s->end_piece);
    int from;
    std::vector<int> demote;
    {
        std::lock_guard<std::mutex> lk(s->win_mu);
        if (s->ra_hi > hi) {
            for (int q = hi + 1; q <= s->ra_hi; ++q) demote.push_back(q);
            s->ra_hi = hi;
        }
        from = std::max(p + 1, s->ra_hi + 1);
        if (hi > s->ra_hi) s->ra_hi = hi;
        if (s->win_lo < 0 || p < s->win_lo) s->win_lo = p;
        if (hi > s->win_hi) s->win_hi = hi;
    }
    if (hi <= p && demote.empty()) return;

    std::vector<char> had((size_t)std::max(0, hi - p), 0);  // [i] = piece p+1+i
    std::vector<int>  drop;
    {
        std::lock_guard<std::mutex> lk(s->piece_mu);
        for (int q = p + 1; q <= hi; ++q)
            had[(size_t)(q - p - 1)] = s->pieces_have.count(q) ? 1 : 0;
        for (int q : demote)
            if (!s->is_protected(q) && !s->pieces_have.count(q)) drop.push_back(q);
    }

    const int step_ms = s->piece_play_ms();
    try {
        for (int q = p + 1; q <= hi; ++q) {
            if (had[(size_t)(q - p - 1)]) continue;
            const int dist = q - p;
            if (dist <= 2) {
                // re-set on every piece: they're next
                s->handle.piece_priority(lt::piece_index_t(q), lt::top_priority);
                s->handle.set_piece_deadline(lt::piece_index_t(q), dist * step_ms);
            } else if (q >= from) {
                // new to the window
                s->handle.piece_priority(lt::piece_index_t(q), lt::download_priority_t(6));
                s->handle.set_piece_deadline(lt::piece_index_t(q), dist * step_ms);
            }
        }
        for (int q : drop) {
            s->handle.reset_piece_deadline(lt::piece_index_t(q));
            s->handle.piece_priority(lt::piece_index_t(q), lt::dont_download);
        }
    } catch (...) {}
}

// serve_range — based on lt2http's Reader::read() pattern
//
// lt2http reads directly from libtorrent storage — no intermediate cache.
// For each piece: wait until downloaded (have_piece), read via read_piece,
// send to socket. Only prioritize current piece + 2 ahead.
// This eliminates the complex async cache pipeline that caused seek delays.
// [primary]: this is the stream's playback request (see handle_connection):
// it alone moves read_head and the trailing window. Ends early (false)
// when the stream stops or [conn] is cancelled.
static bool serve_range(StreamEngine* s, const ConnState& conn, bool primary,
                        TorrReader* reader, socket_t cli,
                        int64_t range_start, int64_t range_end) {
    int64_t cursor = range_start;
    TB_LOG("serve_range: start=%lld end=%lld primary=%d", (long long)range_start, (long long)range_end, (int)primary);
    auto stopped = [&] { return !s->active.load() || conn.cancelled.load(); };

    if (primary) {
        reader->offset = range_start;
        reader->last_access = TorrReader::now_unix();
        s->read_head.store(range_start);
    }
    // A probe asks for nothing past what it reads.
    const int last_wanted = primary ? s->end_piece
        : std::clamp(s->byte_to_piece(range_end), s->start_piece, s->end_piece);

    while (cursor <= range_end && !stopped()) {
        int p = std::clamp(s->byte_to_piece(cursor), s->start_piece, s->end_piece);

        int64_t pfbeg, pfend;
        s->piece_file_range(p, pfbeg, pfend);
        pfend -= 1;

        int64_t sbeg = std::max(cursor, pfbeg);
        int64_t send_end = std::min(range_end, pfend);
        if (send_end < sbeg) { cursor = pfend + 1; continue; }

        // ── lt2http pattern: prioritize current + 2 ahead, then wait ──
        // Like lt2http's Reader::wait_for_piece → prioritize_pieces(start, start+2)
        bool have_it = false;
        {
            std::lock_guard<std::mutex> lk(s->piece_mu);
            have_it = s->pieces_have.count(p) > 0;
        }

        if (!have_it) {
            // Wider deadline pipeline: current + 16 pieces with stagger.
            // The deadline picker orders by deadline, so i=0 still gets
            // priority — the extra entries just keep peer request queues
            // full so the swarm doesn't idle between piece completions.
            // (Previous current+2 window was below libtorrent's own
            //  request pipeline depth → peers sat idle after each piece.)
            // (No further than the read-ahead window: a cache shrunk to
            // save mobile data must shrink this too.)
            const int PIPELINE_AHEAD = std::min(16, s->readahead_pieces());
            TB_LOG("serve_range: piece=%d not ready, prioritizing p..p+%d", p, PIPELINE_AHEAD);
            try {
                s->handle.piece_priority(lt::piece_index_t(p), lt::top_priority);
                s->handle.set_piece_deadline(lt::piece_index_t(p), 0);
            } catch (...) {}
            if (primary)
                s->note_window(p, std::min(p + PIPELINE_AHEAD, last_wanted));
            for (int i = 1; i <= PIPELINE_AHEAD && p + i <= last_wanted; ++i) {
                bool have_next = false;
                { std::lock_guard<std::mutex> lk(s->piece_mu); have_next = s->pieces_have.count(p+i) > 0; }
                if (!have_next) {
                    try {
                        // First two stay at top, rest at priority 6
                        auto pri = (i <= 2) ? lt::top_priority : lt::download_priority_t(6);
                        s->handle.piece_priority(lt::piece_index_t(p+i), pri);
                        s->handle.set_piece_deadline(lt::piece_index_t(p+i), i * 80);
                    } catch (...) {}
                }
            }

            // Wait for piece — like lt2http's sleep_for(300ms) polling loop
            // but using condition variable for zero-latency wakeup
            TB_LOG("serve_range: WAITING for piece=%d", p);
            // No overall deadline: on a slow swarm one piece can take
            // minutes, and cutting the response mid-body made the player
            // see a premature end of file. The wait goes on in 5 s slices
            // while the stream is active and this request current; after
            // each slice the piece is asked for directly (a missed alert),
            // the client checked for (gone: stop), and the piece's
            // priority and deadline set again.
            for (;;) {
                {
                    std::unique_lock<std::mutex> lk(s->piece_mu);
                    s->piece_cv.wait_for(lk, chr::seconds(5), [&] {
                        return stopped() || s->pieces_have.count(p) > 0;
                    });
                    if (stopped()) {
                        TB_LOG("serve_range: ABORT piece=%d", p);
                        return false;
                    }
                    if (s->pieces_have.count(p) > 0) break;
                }
                if (check_have(s, p)) break;
                if (client_gone(cli)) {
                    TB_LOG("serve_range: client gone waiting for piece=%d", p);
                    return false;
                }
                try {
                    s->handle.piece_priority(lt::piece_index_t(p), lt::top_priority);
                    s->handle.set_piece_deadline(lt::piece_index_t(p), 0);
                } catch (...) {}
            }
            TB_LOG("serve_range: piece=%d READY", p);
        }

        // ── piece is downloaded — read data directly via read_piece ──
        // Like lt2http: storage()->readv(b, p, offset, ...)
        // We use read_piece_data which does read_piece → waits for data
        ReadResult rd = read_piece_data(s, conn, p, 10000);
        if (!rd.ok || rd.data.empty()) {
            TB_LOG("serve_range: read_piece_data FAILED piece=%d", p);
            return false;
        }

        // Extract the slice we need from the piece
        int64_t abs_start = s->file_offset + sbeg;
        int64_t piece_start = (int64_t)p * s->piece_length;
        int64_t off = abs_start - piece_start;
        int64_t nb  = send_end - sbeg + 1;

        if (off < 0 || (size_t)off >= rd.data.size()) { cursor = send_end + 1; continue; }
        if ((size_t)(off + nb) > rd.data.size()) nb = (int64_t)rd.data.size() - off;
        if (nb <= 0) { cursor = send_end + 1; continue; }

        // ── disk-read prefetch ──
        // While we're about to block on the socket send for piece p, kick off
        // libtorrent disk reads for the next 1-2 pieces if they're already
        // downloaded. By the time this send finishes and the loop advances,
        // the read_piece_alert for p+1 is already in s->read_results, so
        // read_piece_data(p+1) returns instantly instead of blocking another
        // ~5-15 ms for the disk round trip. Classic socket-I/O ↔ disk-I/O
        // overlap — free throughput on slow disks and during player buffering.
        for (int i = 1; i <= 2; ++i) {
            int np = p + i;
            if (np > s->end_piece) break;
            bool have_np = false;
            { std::lock_guard<std::mutex> lk(s->piece_mu); have_np = s->pieces_have.count(np) > 0; }
            if (!have_np) break;  // not downloaded yet → no point prefetching
            // skip if already cached or result already buffered
            bool already = s->cache && s->cache->has(np);
            if (!already) {
                std::lock_guard<std::mutex> rlk(s->read_mu);
                if (s->read_results.count(np)) already = true;
            }
            if (already) continue;
            try { s->handle.read_piece(lt::piece_index_t(np)); } catch (...) {}
        }

        if (send_all(cli, rd.data.data() + off, (int)nb) < 0)
            return false;

        cursor = sbeg + nb;
        if (!primary) continue;

        extend_readahead(s, p);

        reader->offset = cursor;
        reader->last_access = TorrReader::now_unix();
        s->read_head.store(cursor);

        if (s->stream_state.load() != LT_STREAM_READY)
            s->stream_state.store(LT_STREAM_READY);

        // Trailing retention — keep last N played pieces for re-reads.
        // Only drop pieces that fall off the trailing window.
        {
            std::lock_guard<std::mutex> tlk(s->trailing_mu);
            // avoid duplicates (piece already in trailing window)
            if (s->trailing_pieces.empty() || s->trailing_pieces.back() != p)
                s->trailing_pieces.push_back(p);
            while ((int)s->trailing_pieces.size() > StreamEngine::TRAILING_WINDOW) {
                int old_p = s->trailing_pieces.front();
                s->trailing_pieces.pop_front();
                try {
                    s->handle.piece_priority(lt::piece_index_t(old_p), lt::dont_download);
                } catch (...) {}
                // Release cache memory for evicted piece
                if (s->cache) s->cache->drop(old_p);
            }
        }
    }
    TB_LOG("serve_range: DONE cursor=%lld end=%lld", (long long)cursor, (long long)range_end);
    return true;
}

// On a seek: the pieces raised around the old position that are not had,
// not in the new window [new_lo, new_hi] and not head or tail go back to
// dont_download — otherwise up to a whole window (tens to hundreds of MB)
// kept downloading at the old spot after every seek.
static void drop_old_window(StreamEngine* s, int new_lo, int new_hi) {
    int lo, hi;
    {
        std::lock_guard<std::mutex> lk(s->win_mu);
        lo = s->win_lo;
        hi = std::max(s->win_hi, s->ra_hi);
        s->win_lo = new_lo;
        s->win_hi = new_hi;
        s->ra_hi  = -1;   // the read-ahead starts over from the new spot
    }
    if (lo < 0 || hi < lo) return;
    std::vector<int> drop;
    {
        std::lock_guard<std::mutex> lk(s->piece_mu);
        for (int q = lo; q <= hi; ++q) {
            if (q >= new_lo && q <= new_hi) continue;
            if (s->is_protected(q) || s->pieces_have.count(q)) continue;
            drop.push_back(q);
        }
    }
    for (int q : drop) {
        try { s->handle.piece_priority(lt::piece_index_t(q), lt::dont_download); }
        catch (...) {}
    }
}

// handle_connection — port of torr/stream.go Stream()
// Each connection creates a TorrReader (like TorrServer's t.NewReader(file))
// and uses it for the lifetime of the connection
static void handle_connection(StreamEngine* s, socket_t cli, int reader_id) {
    // port of stream.go: atomic.AddInt32(&activeStreams, 1)
    StreamEngine::active_streams.fetch_add(1);

    TorrReader* reader = nullptr;
    auto conn = std::make_shared<ConnState>();
    try {

    // Create reader for this connection — port of t.NewReader(file)
    // (assigned to the outer variable, so cleanup closes it)
    reader = s->cache->new_reader(
        reader_id, s->file_index, s->file_offset, s->file_size);

    // port of: reader.SetResponsive() — set readahead to 16MB (TorrServer's updateRA)
    reader->set_readahead(StreamEngine::FIXED_READAHEAD);

    // Adjust all readers' readahead — port of torrent.go updateRA()
    s->cache->adjust_readahead(StreamEngine::FIXED_READAHEAD);

    int opt = 1;
    ::setsockopt(cli, IPPROTO_TCP, TCP_NODELAY, (const char*)&opt, sizeof(opt));
    int sndbuf = 2 * 1024 * 1024;
    ::setsockopt(cli, SOL_SOCKET, SO_SNDBUF, (const char*)&sndbuf, sizeof(sndbuf));

#ifdef _WIN32
    DWORD tv = 36000000;
    ::setsockopt(cli, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    ::setsockopt(cli, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));
#else
    struct timeval tv;
    tv.tv_sec = 36000; tv.tv_usec = 0;
    ::setsockopt(cli, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ::setsockopt(cli, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif

    while (s->active.load()) {
        char buf[8192] = {};
        int total = 0;
        bool header_complete = false;
        while (total < (int)sizeof(buf) - 1 && s->active.load()) {
            int n = ::recv(cli, buf + total, (int)sizeof(buf) - 1 - total, 0);
            if (n <= 0) goto cleanup;
            total += n;
            for (int i = std::max(0, total - 4); i <= total - 4; ++i) {
                if (buf[i]=='\r' && buf[i+1]=='\n' && buf[i+2]=='\r' && buf[i+3]=='\n') {
                    header_complete = true; break;
                }
            }
            if (header_complete) break;
        }
        if (!header_complete || !s->active.load()) goto cleanup;

        {
            std::string req(buf, (size_t)total);

            bool is_options = req.find("OPTIONS ") != std::string::npos;
            bool is_head    = req.find("HEAD ") != std::string::npos;
            bool is_get     = req.find("GET ")  != std::string::npos;

            if (is_options) {
                const char* cors =
                    "HTTP/1.1 204 No Content\r\n"
                    "Access-Control-Allow-Origin: *\r\n"
                    "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
                    "Access-Control-Allow-Headers: Range\r\n"
                    "Access-Control-Max-Age: 1728000\r\n"
                    "Content-Length: 0\r\n"
                    "Connection: keep-alive\r\n\r\n";
                if (send_all(cli, cors, (int)strlen(cors)) < 0) goto cleanup;
                continue;
            }

            if (!is_get && !is_head) goto cleanup;

            int64_t fsz = s->file_size;
            if (fsz <= 0) goto cleanup;

            RangeReq rr = parse_range(buf, total);
            int64_t rstart = (rr.valid && rr.start >= 0) ? rr.start : 0;
            int64_t rend   = (rr.valid && rr.end >= 0)   ? rr.end   : fsz - 1;
            rstart = std::clamp(rstart, (int64_t)0, fsz - 1);
            rend   = std::clamp(rend,   rstart,     fsz - 1);
            int64_t clen = rend - rstart + 1;
            bool is_partial = (rr.valid && rr.start >= 0);

            // seek detection — 1-to-1 port of TorrServer's seek path
            //
            // TorrServer's clearPriority() sets pieces OUTSIDE reader ranges to
            // PiecePriorityNone. Then setLoadPriority() sets pieces near reader
            // to descending priorities (Now/Next/Readahead/High/Normal).
            //
            // On seek we use clear_piece_deadlines() + selective pair-based
            // prioritize_pieces() + fresh deadlines on the seek target.
            // This stops old time-critical picks without disrupting peer
            // connections (unlike batch-resetting ALL pieces to dont_download).
            //
            // Which request is playback: a GET that isn't in the file's
            // last few MB (a probe for the container's index) and reads on
            // through the file — no Range, an open-ended one, or at least
            // 1 MB. Only it moves read_head and priorities, and a new one
            // cancels the one before; probes (tail reads, a subtitle
            // hash's 64 KB) run alongside without disturbing it.
            int64_t old_head = s->read_head.load();
            const int64_t tail_bytes = std::min<int64_t>(StreamEngine::PROTECT_BYTES, fsz / 20);
            bool is_tail_req = (rstart >= fsz - tail_bytes);
            bool reads_on = !rr.valid || rr.end < 0 || clen >= 1024 * 1024;
            bool primary = is_get && !is_tail_req && reads_on;
            TB_LOG("handle_conn: rstart=%lld rend=%lld old_head=%lld is_tail=%d primary=%d",
                   (long long)rstart, (long long)rend, (long long)old_head, is_tail_req?1:0, primary?1:0);
            if (primary) {
                std::shared_ptr<ConnState> prev;
                {
                    std::lock_guard<std::mutex> clk(s->conn_mu);
                    prev = std::move(s->primary);
                    s->primary = conn;
                }
                if (prev) s->cancel(*prev);
            }
            if (primary && old_head > 0 && std::abs(rstart - old_head) > 65536) {
                int new_gen;
                {
                    // (under piece_mu, so no waiter misses the change)
                    std::lock_guard<std::mutex> plk(s->piece_mu);
                    new_gen = s->seek_generation.fetch_add(1) + 1;
                }
                TB_LOG("SEEK DETECTED: old_head=%lld new_pos=%lld seek_piece=%d gen=%d",
                       (long long)old_head, (long long)rstart,
                       std::clamp(s->byte_to_piece(rstart), s->start_piece, s->end_piece), new_gen);
                s->stream_state.store(LT_STREAM_SEEKING);
                s->read_head.store(rstart);

                // port of Reader.Seek: update reader position + readerOn()
                reader->offset = rstart;
                reader->last_access = TorrReader::now_unix();
                reader->reader_on();

                // wake old serve_range so it exits on generation mismatch
                s->piece_cv.notify_all();

                // Free stale read_results from the old playback position.
                // Without this, each seek leaks ~2MB of piece data that
                // serve_range was about to consume but abandoned.
                {
                    std::lock_guard<std::mutex> rlk(s->read_mu);
                    s->read_results.clear();
                }
                s->read_cv.notify_all();

                // Flush trailing retention window — drop old pieces to
                // free bandwidth for the new seek position
                {
                    std::lock_guard<std::mutex> tlk(s->trailing_mu);
                    for (int old_p : s->trailing_pieces) {
                        try {
                            s->handle.piece_priority(
                                lt::piece_index_t(old_p), lt::dont_download);
                        } catch (...) {}
                        // and their memory, which clear() alone kept
                        if (s->cache) s->cache->drop(old_p);
                    }
                    s->trailing_pieces.clear();
                }

                int seek_piece = std::clamp(s->byte_to_piece(rstart),
                                            s->start_piece, s->end_piece);

                // The preload is for the old position: stop it.
                s->preloading.store(false);
                drop_old_window(s, seek_piece,
                    std::min(seek_piece + std::min(StreamEngine::SEEK_WINDOW,
                                                   s->readahead_pieces()),
                             s->end_piece));

                try {
                    // Minimal seek path — just unblock the picker, then let
                    // serve_range do its normal 16-piece + 80ms gradient on
                    // the very first piece it processes.
                    //
                    // Previous version did prioritize_pieces(full_vec) +
                    // 4-piece window + 300ms stagger. That fought serve_range
                    // (which immediately wanted 16 pieces) and added 1.2s of
                    // artificial seek latency from the stagger alone.
                    //
                    // Keep this path tiny:
                    //   1. clear deadlines (cancels old time-critical picks
                    //      → cancel_non_critical patch fires immediately)
                    //   2. fire ONE deadline on the seek target so the
                    //      picker pivots NOW, before the first serve_range
                    //      iteration runs (~1ms later)
                    //   3. force-resume in case the torrent went to seeding
                    s->handle.clear_piece_deadlines();
                    s->handle.piece_priority(
                        lt::piece_index_t(seek_piece), lt::top_priority);
                    s->handle.set_piece_deadline(
                        lt::piece_index_t(seek_piece), 0);
                    s->handle.resume();
                    // If the seek target is already on disk, kick a read
                    // immediately so serve_range's read_piece_data returns
                    // without an extra round-trip. (Only then: for a piece
                    // not had, the read fails, and the failure could be
                    // taken for the answer to a later read.)
                    bool had;
                    {
                        std::lock_guard<std::mutex> plk(s->piece_mu);
                        had = s->pieces_have.count(seek_piece) > 0;
                    }
                    if (had) s->handle.read_piece(lt::piece_index_t(seek_piece));
                } catch (...) {}
            }

            // get filename — port of stream.go MIME detection
            std::string filename = "video.mp4";
            if (s->ti) {
                try { filename = s->ti->files().file_name(lt::file_index_t{s->file_index}).to_string(); }
                catch (...) {}
            }

            // build response headers — port of stream.go header setup
            const std::string& etag_raw = s->url;
            std::ostringstream hdr;
            if (is_partial) {
                hdr << "HTTP/1.1 206 Partial Content\r\n";
                hdr << "Content-Range: bytes " << rstart << "-" << rend << "/" << fsz << "\r\n";
            } else {
                hdr << "HTTP/1.1 200 OK\r\n";
            }
            hdr << "Content-Type: " << get_mime(filename) << "\r\n";
            hdr << "Content-Length: " << clen << "\r\n";
            hdr << "Accept-Ranges: bytes\r\n";
            // port of stream.go: resp.Header().Set("Connection", "close")
            hdr << "Connection: close\r\n";
            // port of stream.go: ETag header
            hdr << "ETag: \"" << std::hash<std::string>{}(etag_raw) << "\"\r\n";
            hdr << "Access-Control-Allow-Origin: *\r\n";
            hdr << "Access-Control-Allow-Headers: Range\r\n";
            // port of stream.go: DLNA headers
            hdr << "transferMode.dlna.org: Streaming\r\n";
            hdr << "contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;"
                   "DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n";
            hdr << "Cache-Control: no-store, no-cache\r\n\r\n";

            std::string h = hdr.str();
            if (send_all(cli, h.c_str(), (int)h.size()) < 0) goto cleanup;

            if (is_get) {
                TB_LOG("handle_conn: calling serve_range rstart=%lld rend=%lld", (long long)rstart, (long long)rend);
                bool sr_ok = serve_range(s, *conn, primary, reader, cli, rstart, rend);
                TB_LOG("handle_conn: serve_range returned %d", (int)sr_ok);
                if (!sr_ok) goto cleanup;
            }

            // Connection: close — break after one request like TorrServer
            goto cleanup;
        }
    }

cleanup:
    // no longer the playback request, if it was
    {
        std::lock_guard<std::mutex> clk(s->conn_mu);
        if (s->primary == conn) s->primary.reset();
    }
    // port of stream.go: defer t.CloseReader(reader)
    try {
        if (s->cache && reader) s->cache->close_reader(reader);
    } catch (...) {}

    // port of stream.go: defer atomic.AddInt32(&activeStreams, -1)
    StreamEngine::active_streams.fetch_add(-1);

    } catch (...) {
        // Never crash in client handler — just clean up
        StreamEngine::active_streams.fetch_add(-1);
    }
}

// run_http_server — accepts connections, each gets its own TorrReader
// port of TorrServer's multi-connection model where each http.ServeContent
// call creates its own Reader
static void run_http_server(StreamEngine* stream) {
    // The listen socket was bound and set listening by lt_start_stream;
    // from here on only this thread touches it, and closes it on the way out.
    const socket_t sock = stream->listen_sock;
    try {
        while (stream->active.load()) {
            // poll(), not select(): the session's many peer sockets can push
            // this descriptor past FD_SETSIZE.
            pollfd_t fds[2] = {};
            int nfds = 1;
            fds[0].fd     = sock;
            fds[0].events = POLL_READ_EV;
#ifndef _WIN32
            if (stream->wake_fds[0] >= 0) {
                fds[1].fd     = stream->wake_fds[0];
                fds[1].events = POLLIN;
                nfds = 2;
            }
#endif
            // The timeout is only a backstop: wake_server() ends the wait.
            int r = POLL_SOCKETS(fds, nfds, 1000);
            if (r < 0) {
                if (SOCK_ERRNO() == SOCK_EINTR) continue;
                break;
            }
            if (r == 0) continue;
#ifndef _WIN32
            if (nfds == 2 && fds[1].revents) {
                char drain[64];
                while (::read(stream->wake_fds[0], drain, sizeof(drain)) > 0) {}
                continue;  // the loop condition looks at active
            }
#endif
            if (fds[0].revents & (POLLERR | POLLNVAL)) break;
            if (!(fds[0].revents & POLL_READ_EV)) continue;

            sockaddr_in ca{}; socklen_t_ cl = sizeof(ca);
            socket_t cli = ::accept(sock, (sockaddr*)&ca, (socklen_t*)&cl);
            if (cli == SOCKET_INVALID) {
                // (e.g. out of descriptors: don't spin on a ready socket)
                if (SOCK_ERRNO() != SOCK_EINTR)
                    std::this_thread::sleep_for(chr::milliseconds(20));
                continue;
            }
            if (!stream->active.load()) {  // the wake-up connection, or late
                CLOSESOCKET(cli);
                break;
            }

            // each new connection gets its own reader — port of TorrServer model
            // TorrServer does NOT kill old connections; it supports concurrent readers
            int rid = stream->next_reader_id.fetch_add(1);

            // register client socket for forced shutdown
            {
                std::lock_guard<std::mutex> lk(stream->clients_mu);
                stream->client_sockets[rid] = cli;

                // join and erase finished client threads
                for (auto it = stream->client_threads.begin(); it != stream->client_threads.end(); ) {
                    if (stream->finished_clients.count(it->first)) {
                        if (it->second.joinable()) it->second.join();
                        stream->finished_clients.erase(it->first);
                        it = stream->client_threads.erase(it);
                    } else {
                        ++it;
                    }
                }
            }

            try {
                std::thread t([stream, cli, rid]() {
                    try {
                        handle_connection(stream, cli, rid);
                    } catch (...) {}
                    // Unregistered before it's closed, so the shutdown below
                    // can't hit a descriptor number already reused.
                    try {
                        std::lock_guard<std::mutex> lk(stream->clients_mu);
                        stream->client_sockets.erase(rid);
                        stream->finished_clients.insert(rid);
                    } catch (...) {}
                    CLOSESOCKET(cli);
                });
                std::lock_guard<std::mutex> lk(stream->clients_mu);
                stream->client_threads[rid] = std::move(t);
            } catch (...) {
                // no thread: drop the connection
                {
                    std::lock_guard<std::mutex> lk(stream->clients_mu);
                    stream->client_sockets.erase(rid);
                }
                CLOSESOCKET(cli);
            }
        }
    } catch (...) {}

    try {
        CLOSESOCKET(sock);
        stream->listen_sock = SOCKET_INVALID;

        // shut down all client sockets to unblock recv()/send() in client threads
        {
            std::lock_guard<std::mutex> lk(stream->clients_mu);
            for (auto& kv : stream->client_sockets) {
#ifdef _WIN32
                ::shutdown(kv.second, SD_BOTH);
#else
                ::shutdown(kv.second, SHUT_RDWR);
#endif
            }
        }

        // join all client threads before returning — prevents use-after-free
        // on StreamEngine's mutexes when the stream is destroyed
        std::unordered_map<int, std::thread> threads_to_join;
        {
            std::lock_guard<std::mutex> lk(stream->clients_mu);
            threads_to_join = std::move(stream->client_threads);
            stream->client_threads.clear();
            stream->finished_clients.clear();
        }
        for (auto& kv : threads_to_join) {
            if (kv.second.joinable()) kv.second.join();
        }
    } catch (...) {}
}

// ── preload — port of torr/preload.go Preload() ─────────────────────────────
// Preloads head and tail of file in parallel before streaming
static void preload_stream(StreamEngine* s, int64_t preload_bytes) {
    // (preloading was set by lt_preload_stream, which owns the flag until
    // this thread clears it at the end.)
    if (preload_bytes <= 0) { s->preloading.store(false); return; }
    s->preload_size.store(preload_bytes);

    if (preload_bytes > s->file_size)
        preload_bytes = s->file_size;

    // port of preload.go: startend → 8/16 MB
    int64_t startend = s->piece_length;
    if (startend < 8 * 1024 * 1024)
        startend = 8 * 1024 * 1024;

    int64_t reader_start_end = preload_bytes - startend;
    if (reader_start_end < 0) reader_start_end = preload_bytes;
    if (reader_start_end > s->file_size) reader_start_end = s->file_size;

    int64_t reader_end_start = s->file_size - startend;

    // head preload — port of main preload section
    int head_piece = s->start_piece;
    int head_end_piece = s->byte_to_piece(reader_start_end);
    head_end_piece = std::min(head_end_piece, s->end_piece);

    for (int p = head_piece; p <= head_end_piece && s->active.load() && s->preloading.load(); ++p) {
        // wait for piece data in cache (alert thread eagerly pre-fetches)
        if (!wait_for_piece(s, p, 30000)) break;
        s->preloaded_bytes.fetch_add(s->piece_length);
    }

    // tail preload — port of end range preload goroutine
    if (reader_end_start > reader_start_end) {
        int tail_piece = s->byte_to_piece(reader_end_start);
        tail_piece = std::max(tail_piece, s->start_piece);

        for (int p = tail_piece; p <= s->end_piece && s->active.load() && s->preloading.load(); ++p) {
            if (!wait_for_piece(s, p, 30000)) break;
            s->preloaded_bytes.fetch_add(s->piece_length);
        }
    }

    s->preloading.store(false);
}

// ── C API ───────────────────────────────────────────────────────────────────────

extern "C" {

TORRENT_API lt_session_t lt_create_session(const char* iface, int dl, int ul) {
    return lt_create_session_with_state(iface, dl, ul, nullptr);
}

// The DHT routing table saved by lt_save_session_state, read back so a new
// session starts out knowing live nodes instead of bootstrapping from the
// router nodes alone — which can take a minute or more, and is why the
// first stream after launch was the slow one. Missing or unreadable state
// just means a cold start, as before.
static lt::session_params read_saved_state(const char* path) {
    if (!path || !*path) return {};
    try {
        std::ifstream in(path, std::ios::binary);
        std::vector<char> buf((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
        if (buf.empty()) return {};
        return lt::read_session_params(buf, lt::session_handle::save_dht_state);
    } catch (...) {
        return {};
    }
}

TORRENT_API lt_session_t lt_create_session_with_state(const char* iface,
                                                      int dl, int ul,
                                                      const char* state_path) {
    try {
        lt::settings_pack sp;

        // alert categories
        sp.set_int(lt::settings_pack::alert_mask,
            lt::alert_category::status
            | lt::alert_category::error
            | lt::alert_category::storage
            | lt::alert_category::piece_progress);

        sp.set_str(lt::settings_pack::listen_interfaces,
            (iface && *iface) ? iface : "0.0.0.0:6881,[::]:6881");

        if (dl > 0) sp.set_int(lt::settings_pack::download_rate_limit, dl);
        if (ul > 0) sp.set_int(lt::settings_pack::upload_rate_limit,   ul);

        // ── connection speed — get peers fast ──
        sp.set_int (lt::settings_pack::connection_speed,          200);
        sp.set_int (lt::settings_pack::torrent_connect_boost,     200);
        sp.set_bool(lt::settings_pack::smooth_connects,           false);
        // Session-wide cap. Per-torrent cap (default 25) is what actually
        // governs streaming fanout — see set_max_connections() in
        // lt_start_stream. Keep this comfortably above per-torrent * active.
        sp.set_int (lt::settings_pack::connections_limit,         200);
        sp.set_int (lt::settings_pack::min_reconnect_time,        5);
        sp.set_int (lt::settings_pack::max_failcount,             3);
        sp.set_int (lt::settings_pack::peer_connect_timeout,      5);
        sp.set_int (lt::settings_pack::handshake_timeout,         5);

        // ── timeouts — detect slow/stalled peers quickly for streaming ──
        sp.set_int (lt::settings_pack::piece_timeout,             5);
        sp.set_int (lt::settings_pack::request_timeout,           5);
        sp.set_int (lt::settings_pack::peer_timeout,              15);
        sp.set_int (lt::settings_pack::inactivity_timeout,        15);

        // ── request pipeline — short queue time = fast seek response ──
        // request_queue_time is SECONDS of outstanding requests per peer.
        // At 3s, after a priority change peers take up to 3s to drain the
        // pipe before serving new pieces. 1s = 3x faster seek response.
        sp.set_int (lt::settings_pack::request_queue_time,        1);
        sp.set_int (lt::settings_pack::max_out_request_queue,     500);
        sp.set_int (lt::settings_pack::max_allowed_in_request_queue, 2000);

        // ── piece picking — WE control priorities ──
        sp.set_bool(lt::settings_pack::auto_sequential,           false);
        // piece_extent_affinity=true: keep a peer downloading the same
        // file region instead of jumping. Reduces piece-completion variance
        // (= stutter). Designed exactly for streaming.
        sp.set_bool(lt::settings_pack::piece_extent_affinity,     true);
        // strict_end_game_mode=false: enables block-level duplication on
        // the trailing edge of in-progress pieces. With strict=true and a
        // 2-piece window, end-game NEVER triggers — peers sit waiting on a
        // single slow block. false = duplicate the last blocks across peers.
        sp.set_bool(lt::settings_pack::strict_end_game_mode,      false);
        sp.set_bool(lt::settings_pack::prioritize_partial_pieces, true);
        sp.set_int (lt::settings_pack::initial_picker_threshold,  0);

        // ── disk I/O ──
        sp.set_int (lt::settings_pack::aio_threads,               4);
        sp.set_int (lt::settings_pack::hashing_threads,           2);
        // 64MB lets the disk pipeline absorb burst writes when many peers
        // deliver simultaneously (common right after a seek).
        sp.set_int (lt::settings_pack::max_queued_disk_bytes,     64 * 1024 * 1024);
        sp.set_int (lt::settings_pack::disk_io_read_mode,         lt::settings_pack::enable_os_cache);
        sp.set_int (lt::settings_pack::disk_io_write_mode,        lt::settings_pack::enable_os_cache);
        sp.set_int (lt::settings_pack::file_pool_size,            100);
        sp.set_bool(lt::settings_pack::no_atime_storage,          true);

        // ── upload — unlimited unchoke so peers reciprocate (tit-for-tat) ──
        sp.set_int (lt::settings_pack::unchoke_slots_limit,       -1);
        sp.set_int (lt::settings_pack::active_seeds,              0);
        sp.set_int (lt::settings_pack::suggest_mode,              lt::settings_pack::suggest_read_cache);

        // ── DHT + discovery ──
        sp.set_bool(lt::settings_pack::enable_dht,                true);
        sp.set_bool(lt::settings_pack::enable_lsd,                true);
        sp.set_bool(lt::settings_pack::enable_upnp,               true);
        sp.set_bool(lt::settings_pack::enable_natpmp,             true);
        sp.set_str (lt::settings_pack::dht_bootstrap_nodes,
            "dht.libtorrent.org:25401,"
            "router.bittorrent.com:6881,"
            "dht.transmissionbt.com:6881,"
            "router.utorrent.com:6881");
        sp.set_int (lt::settings_pack::dht_announce_interval,     60);
        sp.set_bool(lt::settings_pack::announce_to_all_trackers,  true);
        sp.set_bool(lt::settings_pack::announce_to_all_tiers,     true);

        // ── general ──
        sp.set_int (lt::settings_pack::active_downloads,          1);
        sp.set_int (lt::settings_pack::active_limit,              10);
        sp.set_int (lt::settings_pack::alert_queue_size,          10000);
        // Off: torrents want only the pieces a stream asks for (N-M7), so a
        // torrent is "finished" whenever its window is done — and with this
        // on libtorrent then dropped its seeds (and told peers it was upload-
        // only, so libtorrent seeds dropped it), just before the next
        // window or the next stream needed them.
        sp.set_bool(lt::settings_pack::close_redundant_connections, false);
        sp.set_int (lt::settings_pack::peer_turnover,             5);
        sp.set_int (lt::settings_pack::peer_turnover_interval,    30);
        // Off: with it on, a torrent added with no resume data (the first
        // launch after resume data began to be kept, or a lost one) never
        // looks at the files already on disk — they were downloaded again.
        sp.set_bool(lt::settings_pack::no_recheck_incomplete_resume, false);
        sp.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
        sp.set_bool(lt::settings_pack::rate_limit_ip_overhead,    false);
        // whole_pieces_threshold=0: parallelize block requests across peers
        // for every piece. At 20s, a 4MB piece comes from ONE peer (~800ms
        // at 5MB/s). Parallel across 10 peers = ~80ms. Single biggest
        // seek-latency win.
        sp.set_int (lt::settings_pack::whole_pieces_threshold,    0);
        sp.set_int (lt::settings_pack::max_peerlist_size,         8000);
        sp.set_bool(lt::settings_pack::dont_count_slow_torrents,  true);

        // ── encryption (MSE/PE) ──
        // pe_enabled (vs pe_forced) keeps plaintext as a fallback so we don't
        // lose peers that don't speak MSE; the encrypted handshake is still
        // tried first, which is what defeats most ISP DPI throttling.
        sp.set_int (lt::settings_pack::in_enc_policy,  lt::settings_pack::pe_enabled);
        sp.set_int (lt::settings_pack::out_enc_policy, lt::settings_pack::pe_enabled);
        // both = negotiate full RC4 stream encryption when the peer supports
        // it (header-only is the libtorrent default and is weaker against
        // DPI). This is the actual ISP-throttling-bypass knob.
        sp.set_int (lt::settings_pack::allowed_enc_level, lt::settings_pack::pe_both);
        sp.set_bool(lt::settings_pack::prefer_rc4,         false);
        sp.set_int (lt::settings_pack::mixed_mode_algorithm, lt::settings_pack::peer_proportional);

        // ── reciprocity boost ──
        // Announce pieces ~500 ms before they finish hashing so peers can
        // start requesting from us before we've even completed the piece.
        // This raises our reciprocity score and gets us better unchoke
        // priority from them on the next round — measurably helps streaming
        // on mid-swarm torrents. Value is in MILLISECONDS, not seconds.
        // 500 ms is enough for ~3-5× a typical WAN round-trip without
        // announcing pieces that may still fail the hash check.
        sp.set_int (lt::settings_pack::predictive_piece_announce, 500);

        // ── tracker discovery ──
        // UDP trackers answer ~10× faster than HTTP and have lower overhead
        // for the tracker operator (=> more reliable scrape data). Try them
        // first when both are available.
        sp.set_bool(lt::settings_pack::prefer_udp_trackers, true);

        // port of btserver.go — spoof as qBittorrent 4.3.9
        sp.set_str (lt::settings_pack::user_agent,                 "qBittorrent/4.3.9");
        sp.set_str (lt::settings_pack::peer_fingerprint,           "-qB4390-");
        sp.set_str (lt::settings_pack::handshake_client_version,   "qBittorrent/4.3.9");

        // buffers
        sp.set_int (lt::settings_pack::send_buffer_watermark,     2 * 1024 * 1024);
        sp.set_int (lt::settings_pack::send_buffer_low_watermark, 64 * 1024);
        sp.set_int (lt::settings_pack::send_buffer_watermark_factor, 150);
        sp.set_int (lt::settings_pack::recv_socket_buffer_size,   1024 * 1024);
        sp.set_int (lt::settings_pack::send_socket_buffer_size,   1024 * 1024);

        lt::session_params params = read_saved_state(state_path);
        params.settings = std::move(sp);
        auto* sw = new SessionWrapper(std::move(params));
        sw->init_default_config();
        sw->start_alert_thread();
        set_err("");
        return reinterpret_cast<lt_session_t>(sw);
    } catch (const std::exception& e) { set_err(e.what()); return nullptr; }
}

TORRENT_API int lt_save_session_state(lt_session_t session,
                                      const char* path) {
    if (!session || !path || !*path) return 0;
    try {
        auto* sw = to_sw(session);
        // (Called on the app being left or closed, and now and then.)
        sw->request_resume_saves(false);
        const auto flags = lt::session_handle::save_dht_state;
        const std::vector<char> buf =
            lt::write_session_params_buf(sw->session.session_state(flags), flags);
        // Written aside and moved into place, so a crash mid-write can't
        // leave a truncated file for the next launch.
        const std::string tmp = std::string(path) + ".tmp";
        {
            std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
            out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
            if (!out) return 0;
        }
        std::remove(path);
        if (std::rename(tmp.c_str(), path) != 0) return 0;
        return 1;
    } catch (const std::exception& e) { set_err(e.what()); return 0; }
}

TORRENT_API void lt_destroy_session(lt_session_t session) {
    if (!session) return;
    auto* sw = to_sw(session);

    // Every torrent's resume data, written (by the alert thread, still
    // running) before anything stops — up to 3 s.
    try {
        sw->request_resume_saves(true);
        for (int i = 0; i < 150 && sw->resume_outstanding.load() > 0; ++i)
            std::this_thread::sleep_for(chr::milliseconds(20));
    } catch (...) {}

    try {
        // stop all streams — move them out so we don't hold streams_mu while
        // joining threads (alert thread also locks streams_mu to deliver pieces,
        // holding it during join would deadlock)
        std::vector<std::shared_ptr<StreamEngine>> streams_to_destroy;
        {
            std::lock_guard<std::mutex> lk(sw->streams_mu);
            for (auto& kv : sw->streams)
                streams_to_destroy.push_back(std::move(kv.second));
            sw->streams.clear();
        }
        for (auto& stream : streams_to_destroy)
            try { begin_shutdown(stream.get()); } catch (...) {}
        // join all threads WITHOUT holding streams_mu
        for (auto& stream : streams_to_destroy)
            try { finish_shutdown(stream.get()); } catch (...) {}
        streams_to_destroy.clear();
    } catch (...) {}

    // Streams stopped earlier still being torn down use sw: wait for them.
    try {
        std::unique_lock<std::mutex> lk(sw->reap_mu);
        sw->reap_cv.wait(lk, [&] { return sw->reaping == 0; });
    } catch (...) {}

    try {
        sw->alert_running = false;
        if (sw->alert_thread.joinable()) sw->alert_thread.join();
    } catch (...) {}

    try { delete sw; } catch (...) {}
}

TORRENT_API void lt_set_alert_callback(lt_session_t session,
                                       lt_alert_callback cb, void* ud) {
    if (!session) return;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->cb_mu);
    sw->dart_callback  = cb;
    sw->dart_user_data = ud;
}

TORRENT_API void lt_poll_alerts(lt_session_t session,
                                lt_alert_callback cb, void* ud) {
    if (!session || !cb) return;
    auto* sw = to_sw(session);
    // Alerts are queued from now on (for 10 s past each call): the first
    // poll after a quiet spell returns only what came in since.
    sw->last_poll_ms.store(SessionWrapper::steady_ms());
    std::deque<AlertRecord> local;
    {
        std::lock_guard<std::mutex> lk(sw->dart_queue_mu);
        local.swap(sw->dart_queue);
    }
    for (auto& r : local)
        cb(r.type, r.torrent_id, r.message.c_str(), ud);
}

// ── torrent management ──────────────────────────────────────────────────────────

TORRENT_API lt_torrent_id lt_add_magnet(lt_session_t session,
                                        const char* uri, const char* path,
                                        int stream_only) {
    if (!session || !uri || !path) { set_err("null arg"); return -1; }
    auto* sw = to_sw(session);
    try {
        lt::error_code ec;
        lt::add_torrent_params atp = lt::parse_magnet_uri(uri, ec);
        if (ec) { set_err(ec.message()); return -1; }
        load_resume(atp, path);
        atp.save_path = path;
        atp.flags &= ~lt::torrent_flags::paused;
        atp.flags &= ~lt::torrent_flags::auto_managed;
        nothing_wanted_until_streamed(atp);

        // Trackerless magnet (only an info-hash, no &tr=...)? Seed it with a
        // curated set of public open trackers so peer discovery doesn't have
        // to wait for DHT bootstrap (which can take 30-60s on a cold start).
        // These are the same trackers shipped by qBittorrent's default
        // "automatically add" list and TorrServer.
        if (atp.trackers.empty()) {
            static const char* kDefaultTrackers[] = {
                "udp://tracker.opentrackr.org:1337/announce",
                "udp://open.demonii.com:1337/announce",
                "udp://open.stealth.si:80/announce",
                "udp://tracker.torrent.eu.org:451/announce",
                "udp://exodus.desync.com:6969/announce",
                "udp://tracker.openbittorrent.com:6969/announce",
                "udp://tracker.dler.org:6969/announce",
                "udp://explodie.org:6969/announce",
            };
            for (auto* t : kDefaultTrackers) atp.trackers.emplace_back(t);
        }

        if (stream_only) {
            atp.storage_mode = lt::storage_mode_sparse;
            atp.flags |= lt::torrent_flags::stop_when_ready;
        }

        lt::torrent_handle h = sw->session.add_torrent(std::move(atp), ec);
        if (ec) { set_err(ec.message()); return -1; }
        h.resume();

        int64_t id = sw->next_id.fetch_add(1);
        {
            std::lock_guard<std::mutex> lk(sw->mu);
            sw->handles[id] = h;
            if (stream_only) sw->ephemeral_torrents.insert(id);
        }
        set_err(""); return id;
    } catch (const std::exception& e) { set_err(e.what()); return -1; }
}

TORRENT_API lt_torrent_id lt_add_torrent_file(lt_session_t session,
                                              const char* fp, const char* path,
                                              int stream_only) {
    if (!session || !fp || !path) { set_err("null arg"); return -1; }
    auto* sw = to_sw(session);
    try {
        lt::error_code ec;
        auto ti = std::make_shared<lt::torrent_info>(fp, ec);
        if (ec) { set_err(ec.message()); return -1; }
        lt::add_torrent_params atp;
        atp.ti = ti; atp.save_path = path;
        load_resume(atp, path);
        atp.flags &= ~lt::torrent_flags::paused;
        atp.flags &= ~lt::torrent_flags::auto_managed;
        nothing_wanted_until_streamed(atp);

        if (stream_only) {
            atp.storage_mode = lt::storage_mode_sparse;
            atp.flags |= lt::torrent_flags::stop_when_ready;
        }

        lt::torrent_handle h = sw->session.add_torrent(std::move(atp), ec);
        if (ec) { set_err(ec.message()); return -1; }
        h.resume();

        int64_t id = sw->next_id.fetch_add(1);
        {
            std::lock_guard<std::mutex> lk(sw->mu);
            sw->handles[id] = h;
            if (stream_only) sw->ephemeral_torrents.insert(id);
        }
        set_err(""); return id;
    } catch (const std::exception& e) { set_err(e.what()); return -1; }
}

TORRENT_API void lt_remove_torrent(lt_session_t session,
                                   lt_torrent_id id, int del) {
    if (!session) return;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    auto it = sw->handles.find(id);
    if (it == sw->handles.end()) return;
    if (del) {
        try {
            const auto st = it->second.status(lt::torrent_handle::query_save_path);
            std::error_code fec;
            std::filesystem::remove(
                resume_file(st.save_path, it->second.info_hashes()), fec);
        } catch (...) {}
    }
    sw->session.remove_torrent(it->second,
        del ? lt::session::delete_files : lt::remove_flags_t{});
    sw->handles.erase(it);
    sw->ephemeral_torrents.erase(id);
}

TORRENT_API void lt_pause_torrent(lt_session_t session, lt_torrent_id id) {
    if (!session) return;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    auto it = sw->handles.find(id);
    if (it != sw->handles.end() && it->second.is_valid()) {
        try { it->second.pause(); } catch (...) {}
        // What it got, kept now: a paused torrent is one left (a player
        // closed, a head start not taken).
        if (!sw->ephemeral_torrents.count(id)) {
            try {
                if (it->second.torrent_file()) {
                    sw->resume_outstanding.fetch_add(1);
                    it->second.save_resume_data(lt::torrent_handle::save_info_dict);
                }
            } catch (...) {}
        }
    }
}

TORRENT_API void lt_resume_torrent(lt_session_t session, lt_torrent_id id) {
    if (!session) return;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    auto it = sw->handles.find(id);
    if (it != sw->handles.end() && it->second.is_valid())
        try { it->second.resume(); } catch (...) {}
}

TORRENT_API void lt_recheck_torrent(lt_session_t session, lt_torrent_id id) {
    if (!session) return;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    auto it = sw->handles.find(id);
    if (it != sw->handles.end() && it->second.is_valid())
        try { it->second.force_recheck(); } catch (...) {}
}

// ── status queries ──────────────────────────────────────────────────────────────

TORRENT_API int lt_get_torrent_count(lt_session_t session) {
    if (!session) return 0;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    return (int)sw->handles.size();
}

TORRENT_API int lt_get_all_statuses(lt_session_t session,
                                    lt_torrent_status* out, int max) {
    if (!session || !out || max <= 0) return 0;
    auto* sw = to_sw(session);
    // Handles copied out, then queried without holding mu: each status()
    // is a round trip to the network thread, and the alert thread needs mu.
    std::vector<std::pair<int64_t, lt::torrent_handle>> hs;
    {
        std::lock_guard<std::mutex> lk(sw->mu);
        hs.reserve(sw->handles.size());
        for (auto& kv : sw->handles) hs.emplace_back(kv.first, kv.second);
    }
    int n = 0;
    for (auto& kv : hs) {
        if (n >= max) break;
        if (!kv.second.is_valid()) continue;
        try {
            fill_status(out[n], kv.first, kv.second.status(kStatusFlags));
            ++n;
        } catch (...) {}
    }
    return n;
}

TORRENT_API int lt_get_status(lt_session_t session, lt_torrent_id id,
                              lt_torrent_status* out) {
    if (!session || !out) return 0;
    auto* sw = to_sw(session);
    lt::torrent_handle h;
    {
        std::lock_guard<std::mutex> lk(sw->mu);
        auto it = sw->handles.find(id);
        if (it == sw->handles.end()) return 0;
        h = it->second;
    }
    if (!h.is_valid()) return 0;
    try { fill_status(*out, id, h.status(kStatusFlags)); return 1; } catch (...) { return 0; }
}

// ── file queries ────────────────────────────────────────────────────────────────

TORRENT_API int lt_get_file_count(lt_session_t session, lt_torrent_id id) {
    if (!session) return 0;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    auto it = sw->handles.find(id);
    if (it == sw->handles.end() || !it->second.is_valid()) return 0;
    try { auto ti = it->second.torrent_file(); return ti ? ti->num_files() : 0; }
    catch (...) { return 0; }
}

TORRENT_API int lt_get_files(lt_session_t session, lt_torrent_id id,
                             lt_file_info* out, int max) {
    if (!session || !out || max <= 0) return 0;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    auto it = sw->handles.find(id);
    if (it == sw->handles.end() || !it->second.is_valid()) return 0;
    try {
        auto ti = it->second.torrent_file();
        if (!ti) return 0;
        const lt::file_storage& fs = ti->files();
        int n = 0;
        for (int i = 0; i < fs.num_files() && n < max; ++i, ++n) {
            lt::file_index_t fi{i};
            out[n].index = i;
            out[n].size  = fs.file_size(fi);
            out[n].is_streamable = is_streamable(fs.file_name(fi).to_string()) ? 1 : 0;
            std::string nm = fs.file_name(fi).to_string();
            std::string pt = fs.file_path(fi);
            std::strncpy(out[n].name, nm.c_str(), sizeof(out[n].name) - 1);
            std::strncpy(out[n].path, pt.c_str(), sizeof(out[n].path) - 1);
            out[n].name[sizeof(out[n].name) - 1] = 0;
            out[n].path[sizeof(out[n].path) - 1] = 0;
        }
        return n;
    } catch (...) { return 0; }
}

TORRENT_API void lt_set_file_priorities(lt_session_t session, lt_torrent_id id,
                                        const int32_t* priorities, int count) {
    if (!session || !priorities || count <= 0) return;
    auto* sw = to_sw(session);
    std::lock_guard<std::mutex> lk(sw->mu);
    auto it = sw->handles.find(id);
    if (it == sw->handles.end() || !it->second.is_valid()) return;
    try {
        auto ti = it->second.torrent_file();
        if (!ti) return;
        int nf = ti->files().num_files();
        std::vector<lt::download_priority_t> p;
        p.reserve(nf);
        for (int i = 0; i < nf; ++i)
            p.push_back((i < count && priorities[i]) ? lt::default_priority : lt::dont_download);
        it->second.prioritize_files(p);
        it->second.unset_flags(lt::torrent_flags::stop_when_ready);
        it->second.resume();
    } catch (...) {}
}

// ── streaming ───────────────────────────────────────────────────────────────────

TORRENT_API lt_stream_id lt_start_stream(lt_session_t session,
                                         lt_torrent_id torrent_id,
                                         int file_index,
                                         int64_t max_cache_bytes) {
    if (!session) { set_err("null session"); return -1; }
    auto* sw = to_sw(session);

    lt::torrent_handle handle;
    {
        std::lock_guard<std::mutex> lk(sw->mu);
        auto it = sw->handles.find(torrent_id);
        if (it == sw->handles.end()) { set_err("torrent not found"); return -1; }
        handle = it->second;
    }
    if (!handle.is_valid()) { set_err("invalid handle"); return -1; }

    auto ti = handle.torrent_file();
    if (!ti) { set_err("no metadata yet"); return -1; }
    const lt::file_storage& fs = ti->files();

    // auto-select largest streamable file
    if (file_index < 0) {
        int64_t best = -1; file_index = 0;
        for (int i = 0; i < fs.num_files(); ++i) {
            int64_t sz = fs.file_size(lt::file_index_t{i});
            if (sz > best && is_streamable(fs.file_name(lt::file_index_t{i}).to_string())) {
                best = sz; file_index = i;
            }
        }
    }
    if (file_index < 0 || file_index >= fs.num_files()) {
        set_err("invalid file index"); return -1;
    }

    auto s = std::make_shared<StreamEngine>();
    s->id           = sw->next_stream_id.fetch_add(1);
    s->torrent_id   = torrent_id;
    s->file_index   = file_index;
    s->handle       = handle;
    s->ti           = ti;
    s->piece_length = ti->piece_length();
    s->file_size    = fs.file_size(lt::file_index_t{file_index});
    s->file_offset  = fs.file_offset(lt::file_index_t{file_index});
    s->start_piece  = std::max(0, (int)(s->file_offset / s->piece_length));
    s->end_piece    = std::min((int)ti->num_pieces() - 1,
                     (int)((s->file_offset + s->file_size - 1) / s->piece_length));
    s->total_pieces = s->end_piece - s->start_piece + 1;

    // head/tail protection boundaries
    int prot_pieces = (int)((StreamEngine::PROTECT_BYTES + s->piece_length - 1) / s->piece_length);
    s->head_end_piece  = std::min(s->start_piece + prot_pieces - 1, s->end_piece);
    s->tail_start_piece = std::max(s->end_piece - prot_pieces + 1, s->start_piece);

    // ── Adaptive bitrate estimation ──
    // Estimate media bitrate from file size assuming typical video duration.
    // This is crude but vastly better than a fixed 5 Mbps for ALL files.
    // A 1.2GB file ≈ 1.5h movie ≈ ~1.5 MB/s; a 4GB file ≈ 2h movie ≈ ~3.3 MB/s
    {
        float duration_guess;
        if      (s->file_size < 400LL * 1024 * 1024)            duration_guess = 3600.0f;  // <400MB → 1h (episode)
        else if (s->file_size < 1LL * 1024 * 1024 * 1024)       duration_guess = 5400.0f;  // <1GB → 1.5h
        else if (s->file_size < 3LL * 1024 * 1024 * 1024)       duration_guess = 6600.0f;  // <3GB → 1.8h
        else if (s->file_size < 8LL * 1024 * 1024 * 1024)       duration_guess = 7200.0f;  // <8GB → 2h
        else                                                     duration_guess = 9000.0f;  // 8GB+ → 2.5h
        s->estimated_bitrate_bps = (float)s->file_size / duration_guess;

        // Critical startup: target ~2 seconds of video, but at least 1 piece
        // and at most 5 pieces. For a 4GB file with 4MB pieces and ~3.3MB/s
        // bitrate, this gives max(1, 6.6/4) = 1-2 pieces instead of 5.
        int startup_bytes = (int)(s->estimated_bitrate_bps * 2.0f);
        startup_bytes = std::max(startup_bytes, s->piece_length);
        s->critical_startup_pieces = std::clamp(startup_bytes / s->piece_length, 1, 5);

        TB_LOG("ADAPTIVE: file_size=%lldMB piece=%dKB bitrate_est=%.0fKB/s critical_pieces=%d",
               (long long)(s->file_size / (1024*1024)), s->piece_length / 1024,
               s->estimated_bitrate_bps / 1024.0f, s->critical_startup_pieces);
    }

    // ── TorrCache initialization — port of torrstor.NewCache + Cache.Init ──
    // Use session-level bt_config cache_size, fall back to explicit arg, then default 64MB
    int64_t cache_capacity = (max_cache_bytes > 0) ? max_cache_bytes
                           : (sw->bt_config.cache_size > 0) ? sw->bt_config.cache_size
                           : (64 * 1024 * 1024);
    s->cache = std::make_unique<TorrCache>();
    s->cache->init(cache_capacity, s->piece_length, ti->num_pieces(), handle);
    // ...and how far ahead of playback to download (extend_readahead)
    s->ra_capacity.store(cache_capacity);
    // apply session-level connections_limit to cache AND to libtorrent.
    // The cache field is informational; the actual swarm-fanout cap lives
    // on torrent_handle::set_max_connections(). Without this call, every
    // torrent inherits the session-wide 200 cap and on high-seed swarms
    // the time-critical picker fans block requests across hundreds of
    // peers — head-of-line blocked by the slowest one. TorrServer caps at
    // 25 per torrent for exactly this reason.
    if (sw->bt_config.connections_limit > 0) {
        s->cache->connections_limit = sw->bt_config.connections_limit;
        try { handle.set_max_connections(sw->bt_config.connections_limit); } catch (...) {}
    }
    // apply session-level reader_read_ahead to cache
    if (sw->bt_config.reader_read_ahead >= 5 && sw->bt_config.reader_read_ahead <= 100)
        s->cache->reader_read_ahead_pct = sw->bt_config.reader_read_ahead;

    lt_stream_id sid = s->id;
    StreamEngine* raw = s.get();

    // ── HTTP server: bound and listening before the thread starts, so
    // there's nothing to wait for here ──
    INIT_SOCKETS();
    socket_t sock = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == SOCKET_INVALID) { set_err("HTTP server: no socket"); return -1; }
    {
#ifndef _WIN32
        int opt = 1;
        ::setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&opt, sizeof(opt));
#endif
        sockaddr_in addr{};
        addr.sin_family      = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port        = 0;
        socklen_t_ al = sizeof(addr);
        if (::bind(sock, (sockaddr*)&addr, sizeof(addr)) != 0
                || ::getsockname(sock, (sockaddr*)&addr, (socklen_t*)&al) != 0
                || ::listen(sock, 16) != 0) {
            CLOSESOCKET(sock);
            set_err("HTTP server failed to bind"); return -1;
        }
        raw->server_port = ntohs(addr.sin_port);
        raw->listen_sock = sock;
        raw->url = raw->make_url();  // fixed for the stream's life: built once
    }
#ifndef _WIN32
    // The server's wake-up pipe (without it, the poll timeout still ends
    // its wait, just later).
    if (::pipe(raw->wake_fds) == 0) {
        for (int fd : raw->wake_fds) {
            ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) | O_NONBLOCK);
            ::fcntl(fd, F_SETFD, FD_CLOEXEC);
        }
    } else {
        raw->wake_fds[0] = raw->wake_fds[1] = -1;
    }
#endif

    try {
        raw->server_thread = std::thread([raw]() { run_http_server(raw); });
    } catch (...) {
        CLOSESOCKET(raw->listen_sock);
        raw->listen_sock = SOCKET_INVALID;
        raw->close_wake_fds();
        set_err("HTTP server thread failed"); return -1;
    }

    // In sw->streams before the snapshot of pieces had below, so a
    // piece_finished_alert from here on reaches it: none can fall between
    // the snapshot and the registration.
    {
        std::lock_guard<std::mutex> lk(sw->streams_mu);
        sw->streams[sid] = s;
    }

    try {
        // DO NOT use prioritize_files() here!
        // prioritize_files() is ASYNC — it completes later and resets ALL
        // piece priorities back to match file priorities, undoing our
        // careful prioritize_pieces() call below. This race condition
        // causes libtorrent to download random (rarest-first) pieces.
        // Instead, we control everything at piece granularity below.
        // With storage_mode_sparse, only pieces we download get disk space.
        handle.unset_flags(lt::torrent_flags::stop_when_ready);

        // Set piece priorities BEFORE resume().
        // All pieces start as dont_download, then we enable only what we need.
        std::vector<lt::download_priority_t> prios(
            (size_t)ti->num_pieces(), lt::dont_download);

        // Critical startup pieces — adaptive count based on bitrate estimate.
        // These get top_priority + tight deadlines to minimize time-to-first-frame.
        int crit = s->critical_startup_pieces;
        for (int p = s->start_piece; p <= std::min(s->start_piece + crit - 1, s->end_piece); ++p)
            prios[p] = lt::top_priority;

        // Remaining head pieces at lower priority — they'll download after
        // critical pieces without competing for bandwidth
        for (int p = s->start_piece + crit; p <= s->head_end_piece; ++p)
            prios[p] = lt::download_priority_t(4);

        // Tail pieces for moov atom — priority 5 (below head critical,
        // above remaining head). For large files this prevents tail from
        // stealing bandwidth that the first frame needs.
        for (int p = s->tail_start_piece; p <= s->end_piece; ++p)
            prios[p] = lt::download_priority_t(5);

        handle.prioritize_pieces(prios);

        // Deadlines: critical pieces get tight deadlines (0-100ms),
        // tail gets pushed back (1000ms) so time-critical picker
        // strongly favors head over tail.
        for (int i = 0; i < crit && s->start_piece + i <= s->end_piece; ++i)
            handle.set_piece_deadline(
                lt::piece_index_t(s->start_piece + i), i * 50);
        for (int p = s->tail_start_piece; p <= s->end_piece; ++p)
            handle.set_piece_deadline(lt::piece_index_t(p), 1000);

        // NOW resume — priorities are already set, no random downloads
        handle.resume();

        // Do NOT use sequential_download — let deadlines drive piece order.
        // libtorrent's time-critical picker (via set_piece_deadline) is the
        // proper streaming mechanism. Sequential mode fights deadline-driven
        // scheduling and reduces swarm efficiency during seeks.
        handle.unset_flags(lt::torrent_flags::sequential_download);

        // populate pieces we already have — mark them in pieces_have set.
        // Only load nearby pieces into RAM cache (head + tail).
        // Loading ALL pieces would flood I/O and fill the cache budget.
        // (Merged under piece_mu: the alert thread may be adding too.)
        lt::torrent_status ts = handle.status(lt::torrent_handle::query_pieces);
        std::vector<int> had;
        for (int p = s->start_piece; p <= s->end_piece; ++p)
            if (ts.pieces.get_bit(lt::piece_index_t(p))) had.push_back(p);
        {
            std::lock_guard<std::mutex> lk(s->piece_mu);
            s->pieces_have.insert(had.begin(), had.end());
        }
        for (int p : had) {
            {
                // only pre-load first 2 + tail pieces into the cache
                // (kept minimal to limit RAM — serve_range reads the rest on demand)
                bool is_head = (p <= s->start_piece + 1);
                bool is_tail = (p >= s->tail_start_piece);
                if (is_head || is_tail) {
                    try { handle.read_piece(lt::piece_index_t(p)); } catch (...) {}
                }
            }
        }

    } catch (...) {}

    set_err(""); return sid;
}

// Joins and frees a stopped stream (see lt_stop_stream), then removes its
// torrent when it was a stream-only one.
static void reap_stream(SessionWrapper* sw, std::shared_ptr<StreamEngine> stream,
                        bool remove_torrent) {
    try {
        finish_shutdown(stream.get());
        // (No "restore default file priorities" for the others: that async
        // job could land after the next stream's prioritize_pieces on an
        // episode switch and make the whole pack wanted.)
        if (remove_torrent) {
            lt_remove_torrent(reinterpret_cast<lt_session_t>(sw),
                              stream->torrent_id, 1);
        }
    } catch (...) {}
    stream.reset();
    // Notified under the lock: once it's released destroy may free sw.
    std::lock_guard<std::mutex> lk(sw->reap_mu);
    --sw->reaping;
    sw->reap_cv.notify_all();
}

TORRENT_API void lt_stop_stream(lt_session_t session, lt_stream_id sid) {
    if (!session) return;
    auto* sw = to_sw(session);
    try {
        std::shared_ptr<StreamEngine> stream;
        {
            std::lock_guard<std::mutex> lk(sw->streams_mu);
            auto it = sw->streams.find(sid);
            if (it == sw->streams.end()) return;
            stream = std::move(it->second);
            sw->streams.erase(it);
        }

        // Flags set and waiters woken here; the joins happen on a thread of
        // their own, so the caller (the UI thread) never waits for them.
        begin_shutdown(stream.get());

        bool ephemeral = false;
        {
            std::lock_guard<std::mutex> lk(sw->mu);
            ephemeral = sw->ephemeral_torrents.erase(stream->torrent_id) > 0;
        }

        {
            std::lock_guard<std::mutex> lk(sw->reap_mu);
            ++sw->reaping;
        }
        try {
            std::thread(reap_stream, sw, stream, ephemeral).detach();
        } catch (...) {
            reap_stream(sw, stream, ephemeral);  // no thread: do it here
        }
    } catch (...) {
        // Never crash during stream shutdown
    }
}

static void fill_stream_status(lt_stream_status* out, const StreamEngine* s) {
    out->id         = s->id;
    out->torrent_id = s->torrent_id;
    out->file_index = s->file_index;
    out->file_size  = s->file_size;
    out->read_head  = s->read_head.load();
    out->stream_state = s->stream_state.load();

    // readahead_window — fixed 16MB / piece_length
    out->readahead_window = (s->piece_length > 0)
        ? (int)(StreamEngine::FIXED_READAHEAD / s->piece_length)
        : 16;

    // contiguous buffer from playback position
    int play = std::clamp(s->byte_to_piece(s->read_head.load()),
                          s->start_piece, s->end_piece);
    int contiguous = 0;
    {
        std::lock_guard<std::mutex> lk(const_cast<std::mutex&>(s->piece_mu));
        int p = play;
        while (p <= s->end_piece && s->pieces_have.count(p)) {
            contiguous++; p++;
        }
    }
    out->buffer_pieces = contiguous;

    // Use estimated bitrate for buffer reporting — adaptive to file size
    float bitrate = s->estimated_bitrate_bps;
    out->buffer_seconds = (float)contiguous * s->piece_length / bitrate;

    // telemetry from handle (no optional fields: only the counters are read)
    try {
        lt::torrent_status ts = s->handle.status(lt::status_flags_t{});
        out->active_peers  = ts.num_peers;
        out->download_rate = ts.download_rate;
    } catch (...) {
        out->active_peers  = 0;
        out->download_rate = 0;
    }

    std::strncpy(out->url, s->url.c_str(), sizeof(out->url) - 1);
    out->url[sizeof(out->url) - 1] = 0;
}

TORRENT_API int lt_get_stream_status(lt_session_t session,
                                     lt_stream_id sid, lt_stream_status* out) {
    if (!session || !out) return 0;
    auto* sw = to_sw(session);
    // Filled outside streams_mu (the alert thread needs it); the
    // shared_ptr keeps the stream alive even if it's stopped meanwhile.
    std::shared_ptr<StreamEngine> s;
    {
        std::lock_guard<std::mutex> lk(sw->streams_mu);
        auto it = sw->streams.find(sid);
        if (it == sw->streams.end()) return 0;
        s = it->second;
    }
    fill_stream_status(out, s.get());
    return 1;
}

TORRENT_API int lt_get_all_stream_statuses(lt_session_t session,
                                           lt_stream_status* out, int max) {
    if (!session || !out || max <= 0) return 0;
    auto* sw = to_sw(session);
    std::vector<std::shared_ptr<StreamEngine>> ss;
    {
        std::lock_guard<std::mutex> lk(sw->streams_mu);
        for (auto& kv : sw->streams) {
            if ((int)ss.size() >= max) break;
            ss.push_back(kv.second);
        }
    }
    int n = 0;
    for (auto& s : ss) fill_stream_status(&out[n++], s.get());
    return n;
}

// ── speed limits ────────────────────────────────────────────────────────────────

TORRENT_API void lt_set_download_limit(lt_session_t session, int bps) {
    if (!session) return;
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit, bps);
    to_sw(session)->session.apply_settings(sp);
}

TORRENT_API void lt_set_upload_limit(lt_session_t session, int bps) {
    if (!session) return;
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::upload_rate_limit, bps);
    to_sw(session)->session.apply_settings(sp);
}

// ── utility ─────────────────────────────────────────────────────────────────────

TORRENT_API const char* lt_last_error(void) { return g_last_error.c_str(); }
TORRENT_API const char* lt_version(void)    { return LIBTORRENT_VERSION; }

// ── preload — port of torr/preload.go ───────────────────────────────────────────

TORRENT_API int lt_preload_stream(lt_session_t session, lt_stream_id sid,
                                  int64_t preload_bytes) {
    if (!session) return 0;
    auto* sw = to_sw(session);
    std::shared_ptr<StreamEngine> sp;
    {
        std::lock_guard<std::mutex> lk(sw->streams_mu);
        auto it = sw->streams.find(sid);
        if (it == sw->streams.end()) return 0;
        sp = it->second;
    }
    StreamEngine* s = sp.get();

    // Under preload_mu (not streams_mu, which the alert thread needs):
    // the stop path joins the thread under it too, and only starts no new
    // one once inactive.
    std::lock_guard<std::mutex> pl(s->preload_mu);
    if (!s->active.load()) return 0;
    // Claims the flag: a second call while one runs returns 0, instead
    // of move-assigning onto a joinable std::thread (std::terminate).
    bool expected = false;
    if (!s->preloading.compare_exchange_strong(expected, true)) return 0;
    // A previous preload that finished (or was stopped by a seek): join
    // it, then take the flag back — its last act was clearing it.
    if (s->preload_thread.joinable()) s->preload_thread.join();
    s->preloading.store(true);

    // default preload 16MB — port of preload.go startend
    if (preload_bytes <= 0) preload_bytes = 16 * 1024 * 1024;

    try {
        s->preload_thread = std::thread([s, preload_bytes]() {
            preload_stream(s, preload_bytes);
        });
    } catch (...) {
        s->preloading.store(false);
        return 0;
    }
    return 1;
}

// ── cache settings — port of settings/btsets.go ─────────────────────────────────

TORRENT_API void lt_set_cache_settings(lt_session_t session, lt_stream_id sid,
                                       int64_t capacity,
                                       int read_ahead_pct,
                                       int connections_limit) {
    if (!session) return;
    auto* sw = to_sw(session);
    std::shared_ptr<StreamEngine> s;
    {
        std::lock_guard<std::mutex> lk(sw->streams_mu);
        auto it = sw->streams.find(sid);
        if (it == sw->streams.end()) return;
        s = it->second;
    }

    // [capacity] sets how far ahead of playback the stream downloads
    // (readahead_pieces: capacity / piece length, 4 to 64 pieces); the
    // player cuts it in the background to save mobile data. The memory
    // cache has its own fixed cap. [read_ahead_pct] is ignored.
    if (capacity > 0)
        s->ra_capacity.store(capacity);
    (void)read_ahead_pct;
    if (connections_limit > 0) {
        // Wire to libtorrent so it actually takes effect on the swarm.
        try { s->handle.set_max_connections(connections_limit); } catch (...) {}
    }
}

// ── engine config — port of settings/btsets.go + btserver.go configure() ────────
// Applies TorrServer-equivalent settings to the libtorrent session.
// Maps BTSets fields → libtorrent settings_pack values, matching the
// exact behavior of btserver.go configure().

TORRENT_API void lt_configure_session(lt_session_t session,
                                      const lt_bt_config* config) {
    if (!session || !config) return;
    auto* sw = to_sw(session);

    // validate + store — port of settings.SetBTSets failsafe checks
    lt_bt_config cfg = *config;

    if (cfg.cache_size == 0)
        cfg.cache_size = 64 * 1024 * 1024;
    if (cfg.connections_limit == 0)
        cfg.connections_limit = 25;
    if (cfg.torrent_disconnect_timeout == 0)
        cfg.torrent_disconnect_timeout = 30;
    if (cfg.reader_read_ahead < 5)
        cfg.reader_read_ahead = 5;
    if (cfg.reader_read_ahead > 100)
        cfg.reader_read_ahead = 100;
    if (cfg.preload_cache < 0)
        cfg.preload_cache = 0;
    if (cfg.preload_cache > 100)
        cfg.preload_cache = 100;

    sw->bt_config = cfg;

    // apply to libtorrent session — port of btserver.go configure()
    lt::settings_pack sp;

    // port of: bt.config.DisableIPv6 = !settings.BTsets.EnableIPv6
    if (!cfg.enable_ipv6) {
        sp.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881");
    }

    // port of: bt.config.DisableTCP / DisableUTP
    // libtorrent doesn't have direct disable flags — use listen_interfaces
    // If both disabled, that's invalid, so skip
    if (cfg.disable_tcp && !cfg.disable_utp) {
        // UTP only — listen on UDP only (libtorrent uses same interfaces for both)
        // libtorrent doesn't directly support TCP-only disable, we approximate
        // by removing TCP from outgoing
    }
    if (cfg.disable_utp && !cfg.disable_tcp) {
        sp.set_bool(lt::settings_pack::enable_outgoing_utp, false);
        sp.set_bool(lt::settings_pack::enable_incoming_utp, false);
    }

    // port of: bt.config.NoDefaultPortForwarding = settings.BTsets.DisableUPNP
    sp.set_bool(lt::settings_pack::enable_upnp,  !cfg.disable_upnp);
    sp.set_bool(lt::settings_pack::enable_natpmp, !cfg.disable_upnp);

    // port of: bt.config.NoDHT = settings.BTsets.DisableDHT
    sp.set_bool(lt::settings_pack::enable_dht, !cfg.disable_dht);

    // port of: bt.config.NoUpload = settings.BTsets.DisableUpload
    if (cfg.disable_upload) {
        sp.set_int(lt::settings_pack::upload_rate_limit, 1); // near-zero upload
        sp.set_int(lt::settings_pack::unchoke_slots_limit, 0);
        sp.set_int(lt::settings_pack::active_seeds, 0);
    }

    // port of: bt.config.EstablishedConnsPerTorrent = settings.BTsets.ConnectionsLimit
    sp.set_int(lt::settings_pack::connections_limit, cfg.connections_limit * 20);

    // port of: bt.config.TotalHalfOpenConns = 500
    // (already hardcoded in lt_create_session, re-apply for safety)

    // port of: bt.config.EncryptionPolicy
    if (cfg.force_encrypt) {
        sp.set_int(lt::settings_pack::in_enc_policy,  lt::settings_pack::pe_forced);
        sp.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_forced);
    } else {
        sp.set_int(lt::settings_pack::in_enc_policy,  lt::settings_pack::pe_enabled);
        sp.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_enabled);
    }

    // port of: rate limits in KB/s → bytes/s
    if (cfg.download_rate_limit > 0) {
        sp.set_int(lt::settings_pack::download_rate_limit, cfg.download_rate_limit * 1024);
    } else {
        sp.set_int(lt::settings_pack::download_rate_limit, 0);
    }
    if (cfg.upload_rate_limit > 0) {
        sp.set_int(lt::settings_pack::upload_rate_limit, cfg.upload_rate_limit * 1024);
    } else if (!cfg.disable_upload) {
        sp.set_int(lt::settings_pack::upload_rate_limit, 0);
    }

    // port of: userAgent spoofing — TorrServer pretends to be qBittorrent 4.3.9
    sp.set_str(lt::settings_pack::user_agent, "qBittorrent/4.3.9");
    sp.set_str(lt::settings_pack::peer_fingerprint, "-qB4390-");
    sp.set_str(lt::settings_pack::handshake_client_version, "qBittorrent/4.3.9");

    try {
        sw->session.apply_settings(sp);
    } catch (...) {}

    // Re-apply stream-local settings to active streams as well. Without
    // this, configureSession() only affects streams created AFTER the call,
    // so changing connections_limit while a stream is already playing does
    // nothing until the user stops and restarts streaming.
    {
        std::lock_guard<std::mutex> lk(sw->streams_mu);
        for (auto& kv : sw->streams) {
            auto* s = kv.second.get();
            if (!s) continue;

            if (cfg.cache_size > 0)
                s->ra_capacity.store(cfg.cache_size);
            if (cfg.connections_limit > 0) {
                try { s->handle.set_max_connections(cfg.connections_limit); } catch (...) {}
            }
        }
    }
}

TORRENT_API void lt_get_default_config(lt_bt_config* out) {
    if (!out) return;
    // port of settings.SetDefaultConfig()
    out->cache_size = 64 * 1024 * 1024;       // 64 MB
    out->reader_read_ahead = 95;               // 95%
    out->preload_cache = 50;                   // 50%
    out->connections_limit = 25;
    out->torrent_disconnect_timeout = 30;      // 30 seconds
    out->force_encrypt = 0;
    out->disable_tcp = 0;
    out->disable_utp = 0;
    out->disable_upload = 0;
    out->disable_dht = 0;
    out->disable_upnp = 0;
    out->enable_ipv6 = 0;
    out->download_rate_limit = 0;
    out->upload_rate_limit = 0;
    out->peers_listen_port = 0;
    out->responsive_mode = 1;
}

// port of stream.go GetActiveStreams()
TORRENT_API int lt_get_active_streams(lt_session_t session) {
    (void)session;
    return StreamEngine::active_streams.load();
}

} // extern "C"
