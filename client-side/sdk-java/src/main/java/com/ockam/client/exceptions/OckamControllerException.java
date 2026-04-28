package com.ockam.client.exceptions;

/** The remote controller HTTP API returned a non-2xx response. */
public class OckamControllerException extends OckamClientException {
    private final int statusCode;
    private final String body;

    public OckamControllerException(String message, int statusCode, String body) {
        super(message);
        this.statusCode = statusCode;
        this.body = body;
    }
    public int getStatusCode() { return statusCode; }
    public String getBody() { return body; }
}
