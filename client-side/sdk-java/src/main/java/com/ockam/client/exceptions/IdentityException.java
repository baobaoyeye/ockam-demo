package com.ockam.client.exceptions;

/** Local identity load or create failed. */
public class IdentityException extends OckamClientException {
    public IdentityException(String message) { super(message); }
    public IdentityException(String message, Throwable cause) { super(message, cause); }
}
