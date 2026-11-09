## gRPC status codes and the error that carries them.

type
  StatusCode* = enum
    scOk = 0, scCancelled, scUnknown, scInvalidArgument, scDeadlineExceeded,
    scNotFound, scAlreadyExists, scPermissionDenied, scResourceExhausted,
    scFailedPrecondition, scAborted, scOutOfRange, scUnimplemented, scInternal,
    scUnavailable, scDataLoss, scUnauthenticated

  Metadata* = seq[(string, string)]
    ## Keys are lower case. Values of keys ending in "-bin" are raw bytes;
    ## they are base64-encoded on the wire by the library.

  GrpcError* = object of CatchableError
    code*: StatusCode
    trailers*: Metadata
    unprocessed*: bool
      ## The server did not start on the call (it reset the stream with REFUSED_STREAM, or sent
      ## GOAWAY below its id), so the same call may be sent again, whatever the method does.

proc newGrpcError*(code: StatusCode; msg: string; trailers: Metadata = @[]): ref GrpcError =
  result = newException(GrpcError, msg)
  result.code = code
  result.trailers = trailers

proc toStatusCode*(n: int): StatusCode =
  ## Codes outside 0..16 map to UNKNOWN, as the spec requires.
  if n >= ord(low(StatusCode)) and n <= ord(high(StatusCode)): StatusCode(n)
  else: scUnknown

proc get*(md: Metadata; key: string): string =
  ## The first value for `key`, or "".
  for (k, v) in md:
    if k == key: return v
