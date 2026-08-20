# The demonstration image for CKA 03.
#
#   ENTRYPOINT = the executable        -> overridden by the pod's `command`
#   CMD        = the default arguments -> overridden by the pod's `args`
#
# Both in EXEC (JSON array) form. Shell form would make /bin/sh PID 1 and your
# process would stop receiving SIGTERM -- see Break It A.
FROM ubuntu:22.04

ENTRYPOINT ["sleep"]
CMD ["5"]
