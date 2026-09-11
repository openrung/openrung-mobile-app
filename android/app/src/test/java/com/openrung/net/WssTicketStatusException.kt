package com.openrung.net

import java.io.IOException

class WssTicketStatusException(
    val status: Int,
    val retryAfterMillis: Long?,
    cause: Throwable? = null,
) : IOException("broker WSS ticket request failed with HTTP status $status", cause)
