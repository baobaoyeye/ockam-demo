"""Exceptions raised by ockam_client."""


class OckamClientError(Exception):
    """Root exception of the SDK. Subclass for specific failure modes."""


class OckamProcessError(OckamClientError):
    """The local `ockam` subprocess failed (exit code, timeout, parse error)."""

    def __init__(self, message: str, *, stderr: str = "", returncode: int | None = None):
        super().__init__(message)
        self.stderr = stderr
        self.returncode = returncode


class OckamControllerError(OckamClientError):
    """The remote controller HTTP API returned a non-2xx response."""

    def __init__(self, message: str, *, status_code: int, body: str = ""):
        super().__init__(message)
        self.status_code = status_code
        self.body = body


class IdentityError(OckamClientError):
    """Local identity (vault / key) load or create failed."""
