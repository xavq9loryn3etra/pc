#pragma once

#ifdef _WIN32
  #ifdef TORRENT_BRIDGE_EXPORTS
    #define TORRENT_API __declspec(dllexport)
  #else
    #define TORRENT_API __declspec(dllimport)
  #endif
#else
  #define TORRENT_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef void*   lt_session_t;
typedef int64_t lt_torrent_id;
typedef int64_t lt_stream_id;

/* torrent states */
#define LT_STATE_ERROR             -2
#define LT_STATE_UNKNOWN           -1
#define LT_STATE_CHECKING_FILES     0
#define LT_STATE_DOWNLOADING_META   1
#define LT_STATE_DOWNLOADING        2
#define LT_STATE_FINISHED           3
#define LT_STATE_SEEDING            4
#define LT_STATE_ALLOCATING         5
#define LT_STATE_CHECKING_RESUME    6

/* stream states */
#define LT_STREAM_IDLE       0
#define LT_STREAM_BUFFERING  1
#define LT_STREAM_READY      2
#define LT_STREAM_SEEKING    3
#define LT_STREAM_ERROR      4

typedef struct {
    lt_torrent_id id;
    char          name[512];
    char          save_path[1024];
    char          error_msg[256];
    int32_t       state;
    float         progress;
    int32_t       download_rate;
    int32_t       upload_rate;
    int64_t       total_done;
    int64_t       total_wanted;
    int64_t       total_uploaded;
    int32_t       num_peers;
    int32_t       num_seeds;
    int32_t       num_pieces;
    int32_t       pieces_done;
    int32_t       is_paused;
    int32_t       is_finished;
    int32_t       has_metadata;
    int32_t       queue_position;
} lt_torrent_status;

typedef struct {
    int32_t index;
    char    name[512];
    char    path[1024];
    int64_t size;
    int32_t is_streamable;
} lt_file_info;

typedef struct {
    lt_stream_id  id;
    lt_torrent_id torrent_id;
    int32_t       file_index;
    char          url[256];
    int64_t       file_size;
    int64_t       read_head;
    int32_t       stream_state;      /* LT_STREAM_* */
    float         buffer_seconds;    /* estimated seconds of data buffered ahead */
    int32_t       buffer_pieces;     /* contiguous completed pieces ahead */
    int32_t       readahead_window;  /* current adaptive readahead size */
    int32_t       active_peers;
    int32_t       download_rate;     /* bytes/s for this stream */
} lt_stream_status;

/* ── port of settings/btsets.go BTSets struct ──
   Fields marked IGNORED are kept only so the layout matches the Dart FFI
   mirror; the engine doesn't read them. */
typedef struct {
    /* Cache */
    int64_t cache_size;              /* bytes, default 64MB: a new stream's
                                        read-ahead (see lt_set_cache_settings)
                                        when lt_start_stream gets none */
    int32_t reader_read_ahead;       /* IGNORED (was percent 5-100) */
    int32_t preload_cache;           /* IGNORED (was percent 0-100) */

    /* Torrent engine */
    int32_t connections_limit;       /* default 25 */
    int32_t torrent_disconnect_timeout; /* IGNORED (was seconds) */
    int32_t force_encrypt;           /* 0=enabled, 1=forced */
    int32_t disable_tcp;             /* IGNORED */
    int32_t disable_utp;             /* 0=enabled (default), 1=disabled */
    int32_t disable_upload;          /* 0=enabled (default), 1=disabled */
    int32_t disable_dht;             /* 0=enabled (default), 1=disabled */
    int32_t disable_upnp;            /* 0=enabled (default), 1=disabled */
    int32_t enable_ipv6;             /* IGNORED: IPv4 and IPv6 are both listened on */
    int32_t download_rate_limit;     /* KB/s, 0=unlimited */
    int32_t upload_rate_limit;       /* KB/s, 0=unlimited */
    int32_t peers_listen_port;       /* 0 = 6881 (default) */

    /* Reader */
    int32_t responsive_mode;         /* IGNORED */
} lt_bt_config;

typedef void (*lt_alert_callback)(int alert_type, lt_torrent_id id,
                                  const char* message, void* user_data);

/* session */
TORRENT_API lt_session_t lt_create_session(const char* listen_interface,
                                           int download_limit,
                                           int upload_limit);
TORRENT_API void         lt_destroy_session(lt_session_t session);

/* Like lt_create_session, also restoring the DHT state saved at
   state_path by lt_save_session_state (NULL, missing or unreadable: a
   cold start). */
TORRENT_API lt_session_t lt_create_session_with_state(
    const char* listen_interface, int download_limit, int upload_limit,
    const char* state_path);
/* Saves the session's DHT state to path. Returns 1 on success. */
TORRENT_API int lt_save_session_state(lt_session_t session, const char* path);

/* engine config — port of settings/btsets.go + btserver.go configure() */
TORRENT_API void lt_configure_session(lt_session_t session,
                                      const lt_bt_config* config);
TORRENT_API void lt_get_default_config(lt_bt_config* out);

/* alerts */
TORRENT_API void lt_set_alert_callback(lt_session_t session,
                                       lt_alert_callback cb, void* user_data);
TORRENT_API void lt_poll_alerts(lt_session_t session,
                                lt_alert_callback cb, void* user_data);

/* torrent management */
TORRENT_API lt_torrent_id lt_add_magnet(lt_session_t session,
                                        const char* magnet_uri,
                                        const char* save_path,
                                        int stream_only);
TORRENT_API lt_torrent_id lt_add_torrent_file(lt_session_t session,
                                              const char* file_path,
                                              const char* save_path,
                                              int stream_only);
TORRENT_API void lt_remove_torrent(lt_session_t session,
                                   lt_torrent_id id, int delete_files);
TORRENT_API void lt_pause_torrent(lt_session_t session, lt_torrent_id id);
TORRENT_API void lt_resume_torrent(lt_session_t session, lt_torrent_id id);
TORRENT_API void lt_recheck_torrent(lt_session_t session, lt_torrent_id id);

/* status queries */
TORRENT_API int lt_get_torrent_count(lt_session_t session);
TORRENT_API int lt_get_all_statuses(lt_session_t session,
                                    lt_torrent_status* out, int max_count);
TORRENT_API int lt_get_status(lt_session_t session, lt_torrent_id id,
                              lt_torrent_status* out);

/* file queries */
TORRENT_API int  lt_get_file_count(lt_session_t session, lt_torrent_id id);
TORRENT_API int  lt_get_files(lt_session_t session, lt_torrent_id id,
                              lt_file_info* out, int max_count);
TORRENT_API void lt_set_file_priorities(lt_session_t session, lt_torrent_id id,
                                        const int32_t* priorities, int count);

/* streaming */
TORRENT_API lt_stream_id lt_start_stream(lt_session_t session,
                                         lt_torrent_id torrent_id,
                                         int file_index,
                                         int64_t max_cache_bytes);
TORRENT_API void         lt_stop_stream(lt_session_t session, lt_stream_id id);
TORRENT_API int          lt_get_stream_status(lt_session_t session,
                                              lt_stream_id id,
                                              lt_stream_status* out);
TORRENT_API int          lt_get_all_stream_statuses(lt_session_t session,
                                                    lt_stream_status* out,
                                                    int max_count);

/* preload — port of torr/preload.go */
TORRENT_API int  lt_preload_stream(lt_session_t session, lt_stream_id id,
                                   int64_t preload_bytes);

/* cache settings. capacity (bytes, > 0 to change): how far ahead of
   playback stream id downloads — capacity / piece length pieces, 4 to 64.
   read_ahead_pct is ignored; connections_limit > 0 caps the torrent's
   peers. */
TORRENT_API void lt_set_cache_settings(lt_session_t session, lt_stream_id id,
                                       int64_t capacity,
                                       int read_ahead_pct,
                                       int connections_limit);

/* speed limits */
TORRENT_API void lt_set_download_limit(lt_session_t session, int bytes_per_sec);
TORRENT_API void lt_set_upload_limit(lt_session_t session, int bytes_per_sec);

// 1 = on mobile data: few unchoke slots (4) and a low upload cap (~64 KB/s);
// 0 = back to the normal settings.
TORRENT_API void lt_set_metered(lt_session_t session, int metered);

// Stops torrent `id`'s streams, pauses it, writes its resume data, and removes
// it from the session WITHOUT deleting its files. Then shrinks what's kept on
// disk: in file `file_index`, only bytes [keep_from, end of file) are kept;
// in every file (including file_index) its head and tail — the same regions
// the stream engine protects for container headers/indexes, at least one
// piece each — are kept too. Every other piece is dropped: cleared from the
// saved resume data so libtorrent will download it again if needed, and its
// bytes are released from the disk (hole punched). keep_from < 0 means
// "don't trim, just release". Blocking — up to about timeout_ms in total;
// the caller runs it off the UI thread.
//
// Returns:
//   >= 0  released (removed from the session) and trimmed: the bytes of
//         downloaded pieces still kept on disk. With keep_from < 0: released
//         only, and the bytes of the pieces had on disk, or 0 if unknown.
//         (lt_last_error may still note files whose space couldn't be
//         released; that isn't an error — their pieces are no longer
//         trusted either way.)
//   -1    released (removed from the session and forgotten by the engine),
//         but nothing trimmed: the resume data couldn't be saved or read,
//         libtorrent didn't let go of the files in time, etc. Nothing was
//         punched. lt_last_error says why.
//   -2    NOT released: the torrent is still in the session exactly as
//         before (unknown id, null session, invalid file_index, or a failure
//         before anything was changed). lt_last_error says why.
// While it runs, lt_add_magnet / lt_add_torrent_file of the same torrent
// wait for it (up to 15 s, then fail).
TORRENT_API int64_t lt_release_and_trim(lt_session_t session, lt_torrent_id id,
                                        int file_index, int64_t keep_from,
                                        int timeout_ms);

/* utility */
TORRENT_API const char* lt_last_error(void);
TORRENT_API const char* lt_version(void);
TORRENT_API int         lt_get_active_streams(lt_session_t session);

#ifdef __cplusplus
}
#endif
