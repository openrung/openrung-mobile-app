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
    val chain = ArrayList<Throwable>()
    var current: Throwable? = error
    while (current != null && seen.add(current)) {
        chain.add(current)
        current = current.cause
    }

    // Android commonly wraps connect(2) failures in ConnectException. Inspect a nested errno
    // first so that a dead local network (ENETDOWN/ENETUNREACH, or any other non-allow-listed
    // errno) cannot be mistaken for proof that only the relay path is blocked. In particular, a
    // doomed device must not proceed to an HTTPS ticket POST merely because of the outer wrapper.
    chain.firstNotNullOfOrNull { it as? ErrnoException }?.let {
        return it.errno in REMOTE_ERRNOS
    }

    for (failure in chain) {
        when (failure) {
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
        }
    }
    return false
}

private val REMOTE_ERRNOS = setOf(
    OsConstants.ECONNABORTED,
    OsConstants.ECONNREFUSED,
    OsConstants.ECONNRESET,
    OsConstants.EHOSTUNREACH,
    OsConstants.ENETRESET,
    OsConstants.EPIPE,
    OsConstants.ETIMEDOUT,
)
