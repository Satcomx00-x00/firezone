/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data.model

internal data class Config(
    val accountId: String?,
    val authBaseUrl: String,
    val apiUrl: String,
    val logFilter: String,
    val token: String?,
)
