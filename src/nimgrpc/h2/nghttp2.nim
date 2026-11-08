## Thin raw bindings to the subset of nghttp2 used by the session wrapper.
##
## Only the I/O-free API is bound: bytes go in with `nghttp2_session_mem_recv2`
## and come out with `nghttp2_session_mem_send2`, so the library never touches
## a socket. Struct layouts are taken from the C header (`importc` + `header`),
## so Nim never has to mirror them byte for byte.

const nghttp2Prefix* {.strdefine.} = "/opt/nghttp2"
  ## Install prefix of a static nghttp2 build (include/ and lib/).

{.passc: "-I" & nghttp2Prefix & "/include".}
{.passl: nghttp2Prefix & "/lib/libnghttp2.a".}

const h = "nghttp2/nghttp2.h"

{.emit: """/*INCLUDESECTION*/
#include <nghttp2/nghttp2.h>
#if NGHTTP2_VERSION_NUM < 0x013900
#error "nimgrpc needs nghttp2 1.57.0 or later (it limits the Rapid Reset attack, CVE-2023-44487)"
#endif
""".}

type
  Nghttp2Info* {.importc: "nghttp2_info", header: h, incompleteStruct.} = object
    versionNum* {.importc: "version_num".}: cint
    versionStr* {.importc: "version_str".}: cstring

proc nghttp2_version*(leastVersion: cint): ptr Nghttp2Info
  {.importc: "nghttp2_version", header: h.}
  ## The version of the linked library (`0` asks for the current one).

type
  Nghttp2Session* {.importc: "nghttp2_session", header: h, incompleteStruct.} = object
  Nghttp2Option* {.importc: "nghttp2_option", header: h, incompleteStruct.} = object
  Nghttp2SessionCallbacks* {.importc: "nghttp2_session_callbacks", header: h,
                             incompleteStruct.} = object
  Nghttp2Ssize* = int  ## ptrdiff_t

  Nghttp2FrameHd* {.importc: "nghttp2_frame_hd", header: h, bycopy.} = object
    length*: csize_t
    stream_id*: int32
    `type`*: uint8
    flags*: uint8

  Nghttp2HeadersFrame* {.importc: "nghttp2_headers", header: h, bycopy.} = object
    hd*: Nghttp2FrameHd
    cat*: cint

  Nghttp2GoawayFrame* {.importc: "nghttp2_goaway", header: h, bycopy.} = object
    hd*: Nghttp2FrameHd
    last_stream_id*: int32
    error_code*: uint32

  Nghttp2Frame* {.importc: "nghttp2_frame", header: h, union, bycopy.} = object
    hd*: Nghttp2FrameHd
    headers*: Nghttp2HeadersFrame
    goaway*: Nghttp2GoawayFrame

  Nghttp2Nv* {.importc: "nghttp2_nv", header: h, bycopy.} = object
    name*: ptr uint8
    value*: ptr uint8
    namelen*: csize_t
    valuelen*: csize_t
    flags*: uint8

  Nghttp2DataSource* {.importc: "nghttp2_data_source", header: h, union, bycopy.} = object
    fd*: cint
    `ptr`*: pointer

  Nghttp2DataSourceReadCallback2* = proc (session: ptr Nghttp2Session; streamId: int32;
      buf: ptr uint8; length: csize_t; dataFlags: ptr uint32;
      source: ptr Nghttp2DataSource; userData: pointer): Nghttp2Ssize {.cdecl.}

  Nghttp2DataProvider2* {.importc: "nghttp2_data_provider2", header: h, bycopy.} = object
    source*: Nghttp2DataSource
    read_callback*: Nghttp2DataSourceReadCallback2

  OnBeginHeadersCb* = proc (session: ptr Nghttp2Session; frame: ptr Nghttp2Frame;
      userData: pointer): cint {.cdecl.}
  OnHeaderCb* = proc (session: ptr Nghttp2Session; frame: ptr Nghttp2Frame;
      name: ptr uint8; namelen: csize_t; value: ptr uint8; valuelen: csize_t;
      flags: uint8; userData: pointer): cint {.cdecl.}
  OnFrameRecvCb* = proc (session: ptr Nghttp2Session; frame: ptr Nghttp2Frame;
      userData: pointer): cint {.cdecl.}
  OnDataChunkRecvCb* = proc (session: ptr Nghttp2Session; flags: uint8; streamId: int32;
      data: ptr uint8; len: csize_t; userData: pointer): cint {.cdecl.}
  OnStreamCloseCb* = proc (session: ptr Nghttp2Session; streamId: int32;
      errorCode: uint32; userData: pointer): cint {.cdecl.}

const
  NGHTTP2_DATA* = 0'u8
  NGHTTP2_HEADERS* = 1'u8
  NGHTTP2_RST_STREAM* = 3'u8
  NGHTTP2_SETTINGS* = 4'u8
  NGHTTP2_PING* = 6'u8
  NGHTTP2_GOAWAY* = 7'u8

  NGHTTP2_FLAG_NONE* = 0'u8
  NGHTTP2_FLAG_END_STREAM* = 0x01'u8
  NGHTTP2_FLAG_ACK* = 0x01'u8

  NGHTTP2_NV_FLAG_NONE* = 0'u8

  NGHTTP2_DATA_FLAG_EOF* = 0x01'u32
  NGHTTP2_DATA_FLAG_NO_END_STREAM* = 0x02'u32

  NGHTTP2_ERR_INVALID_ARGUMENT* = -501
  NGHTTP2_ERR_DEFERRED* = -508
  NGHTTP2_ERR_CALLBACK_FAILURE* = -902

  NGHTTP2_NO_ERROR* = 0'u32
  NGHTTP2_PROTOCOL_ERROR* = 1'u32
  NGHTTP2_INTERNAL_ERROR* = 2'u32
  NGHTTP2_CANCEL* = 8'u32
  NGHTTP2_ENHANCE_YOUR_CALM* = 11'u32

# Callbacks and out-pointers are passed as `pointer`: the C prototypes take
# `const` parameters, which Nim cannot spell, and GCC 14 rejects the mismatch
# of function pointer types (-Wincompatible-pointer-types is an error there).
{.push importc, header: h, cdecl.}
proc nghttp2_session_callbacks_new*(cbs: ptr ptr Nghttp2SessionCallbacks): cint
proc nghttp2_session_callbacks_del*(cbs: ptr Nghttp2SessionCallbacks)
proc nghttp2_session_callbacks_set_on_begin_headers_callback*(
  cbs: ptr Nghttp2SessionCallbacks; cb: pointer)
proc nghttp2_session_callbacks_set_on_header_callback*(
  cbs: ptr Nghttp2SessionCallbacks; cb: pointer)
proc nghttp2_session_callbacks_set_on_frame_recv_callback*(
  cbs: ptr Nghttp2SessionCallbacks; cb: pointer)
proc nghttp2_session_callbacks_set_on_data_chunk_recv_callback*(
  cbs: ptr Nghttp2SessionCallbacks; cb: pointer)
proc nghttp2_session_callbacks_set_on_stream_close_callback*(
  cbs: ptr Nghttp2SessionCallbacks; cb: pointer)

proc nghttp2_session_client_new*(session: ptr ptr Nghttp2Session;
  cbs: ptr Nghttp2SessionCallbacks; userData: pointer): cint
proc nghttp2_session_server_new*(session: ptr ptr Nghttp2Session;
  cbs: ptr Nghttp2SessionCallbacks; userData: pointer): cint
proc nghttp2_option_new*(opt: ptr ptr Nghttp2Option): cint
proc nghttp2_option_del*(opt: ptr Nghttp2Option)
proc nghttp2_option_set_no_auto_window_update*(opt: ptr Nghttp2Option; val: cint)
proc nghttp2_session_client_new2*(session: ptr ptr Nghttp2Session;
  cbs: ptr Nghttp2SessionCallbacks; userData: pointer; opt: ptr Nghttp2Option): cint
proc nghttp2_session_server_new2*(session: ptr ptr Nghttp2Session;
  cbs: ptr Nghttp2SessionCallbacks; userData: pointer; opt: ptr Nghttp2Option): cint
proc nghttp2_session_consume*(session: ptr Nghttp2Session; streamId: int32;
  size: csize_t): cint
proc nghttp2_session_consume_connection*(session: ptr Nghttp2Session;
  size: csize_t): cint
proc nghttp2_session_del*(session: ptr Nghttp2Session)

proc nghttp2_session_mem_recv2*(session: ptr Nghttp2Session; data: ptr uint8;
  len: csize_t): Nghttp2Ssize
proc nghttp2_session_mem_send2*(session: ptr Nghttp2Session;
  data: pointer): Nghttp2Ssize
proc nghttp2_session_want_read*(session: ptr Nghttp2Session): cint
proc nghttp2_session_want_write*(session: ptr Nghttp2Session): cint
proc nghttp2_session_resume_data*(session: ptr Nghttp2Session; streamId: int32): cint

proc nghttp2_submit_settings*(session: ptr Nghttp2Session; flags: uint8;
  iv: pointer; niv: csize_t): cint
proc nghttp2_submit_window_update*(session: ptr Nghttp2Session; flags: uint8;
  streamId: int32; windowSizeIncrement: int32): cint
proc nghttp2_submit_request2*(session: ptr Nghttp2Session; priSpec: pointer;
  nva: ptr Nghttp2Nv; nvlen: csize_t; dataPrd: ptr Nghttp2DataProvider2;
  streamUserData: pointer): int32
proc nghttp2_submit_response2*(session: ptr Nghttp2Session; streamId: int32;
  nva: ptr Nghttp2Nv; nvlen: csize_t; dataPrd: ptr Nghttp2DataProvider2): cint
proc nghttp2_submit_trailer*(session: ptr Nghttp2Session; streamId: int32;
  nva: ptr Nghttp2Nv; nvlen: csize_t): cint
proc nghttp2_submit_rst_stream*(session: ptr Nghttp2Session; flags: uint8;
  streamId: int32; errorCode: uint32): cint
proc nghttp2_submit_goaway*(session: ptr Nghttp2Session; flags: uint8;
  lastStreamId: int32; errorCode: uint32; opaqueData: ptr uint8; len: csize_t): cint
proc nghttp2_session_get_last_proc_stream_id*(session: ptr Nghttp2Session): int32
proc nghttp2_submit_ping*(session: ptr Nghttp2Session; flags: uint8;
  opaqueData: ptr uint8): cint
proc nghttp2_submit_shutdown_notice*(session: ptr Nghttp2Session): cint
proc nghttp2_session_check_request_allowed*(session: ptr Nghttp2Session): cint

proc nghttp2_strerror*(libErrorCode: cint): cstring
{.pop.}
