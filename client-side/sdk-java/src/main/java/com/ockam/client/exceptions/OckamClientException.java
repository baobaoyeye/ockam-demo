package com.ockam.client.exceptions;

/** Root exception of the SDK. Subclass for specific failure modes. */
public class OckamClientException extends RuntimeException {
    public OckamClientException(String message) { super(message); }
    public OckamClientException(String message, Throwable cause) { super(message, cause); }
}
