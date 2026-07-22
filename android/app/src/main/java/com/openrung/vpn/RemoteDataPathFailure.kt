package com.openrung.vpn

import android.system.ErrnoException
import android.system.OsConstants
import com.openrung.net.InternetProbeHttpStatusException
import java.io.EOFException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.ProtocolException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Collections
import java.util.IdentityHashMap
import javax.net.ssl.SSLException

/**
 * Positive allow-list for errors that prove a remote network/data-path failure. Unknown and
 * generic local/platform errors fail closed and therefore cannot authorize WSS fallback.
 */
internal fun isGenuineRemoteDataPathFailure(error: Throwable): Boolean {
    val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
    var current: Throwable? = error
    while (current != null && seen.add(current)) {
        when (current) {
            is InternetProbeHttpStatusException,
            is SocketTimeoutException,
            is UnknownHostException,
            is ConnectException,
            is NoRouteToHostException,
            is PortUnreachableException,
            is ProtocolException,
            is EOFException,
            is SSLException,
            -> return true

            is ErrnoException -> if (current.errno in REMOTE_ERRNOS) return true
        }
        current = current.cause
    }
    return false
}

private val REMOTE_ERRNOS = setOf(
    OsConstants.ECONNABORTED,
    OsConstants.ECONNREFUSED,
    OsConstants.ECONNRESET,
    OsConstants.EHOSTUNREACH,
    OsConstants.ENETDOWN,
    OsConstants.ENETRESET,
    OsConstants.ENETUNREACH,
    OsConstants.EPIPE,
    OsConstants.ETIMEDOUT,
)
