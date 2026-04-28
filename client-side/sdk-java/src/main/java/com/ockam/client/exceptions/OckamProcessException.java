package com.ockam.client.exceptions;

/** The local `ockam` subprocess failed (exit code, timeout, parse error). */
public class OckamProcessException extends OckamClientException {
    private final String stderr;
    private final Integer returncode;

    public OckamProcessException(String message, String stderr, Integer returncode) {
        super(message);
        this.stderr = stderr;
        this.returncode = returncode;
    }
    public OckamProcessException(String message, String stderr, Integer returncode, Throwable cause) {
        super(message, cause);
        this.stderr = stderr;
        this.returncode = returncode;
    }
    public String getStderr() { return stderr; }
    public Integer getReturncode() { return returncode; }
}
