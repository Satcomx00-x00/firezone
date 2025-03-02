/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.settings.ui

import android.content.Context
import android.content.Intent
import android.webkit.URLUtil
import androidx.core.content.FileProvider
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.core.domain.preference.SaveSettingsUseCase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.net.URISyntaxException
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import javax.inject.Inject

@HiltViewModel
internal class SettingsViewModel
    @Inject
    constructor(
        private val getConfigUseCase: GetConfigUseCase,
        private val saveSettingsUseCase: SaveSettingsUseCase,
    ) : ViewModel() {
        private val _uiState = MutableStateFlow(UiState())
        val uiState: StateFlow<UiState> = _uiState

        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        private var accountId = ""
        private var authBaseUrl = ""
        private var apiUrl = ""
        private var logFilter = ""

        fun populateFieldsFromConfig() {
            viewModelScope.launch {
                getConfigUseCase().collect {
                    actionMutableLiveData.postValue(
                        ViewAction.FillSettings(
                            it.accountId.orEmpty(),
                            it.authBaseUrl.orEmpty(),
                            it.apiUrl.orEmpty(),
                            it.logFilter.orEmpty(),
                        ),
                    )
                }
            }
        }

        fun onViewResume(context: Context) {
            val directory = File(context.cacheDir.absolutePath + "/log")
            val totalSize = directory.walkTopDown().filter { it.isFile }.map { it.length() }.sum()

            deleteLogZip(context)

            _uiState.value =
                _uiState.value.copy(
                    logSize = totalSize,
                )
        }

        fun onSaveSettingsCompleted() {
            viewModelScope.launch {
                saveSettingsUseCase(accountId, authBaseUrl, apiUrl, logFilter).collect {
                    actionMutableLiveData.postValue(ViewAction.NavigateBack)
                }
            }
        }

        fun onCancel() {
            actionMutableLiveData.postValue(ViewAction.NavigateBack)
        }

        fun onValidateAccountId(accountId: String) {
            this.accountId = accountId
            onFieldUpdated()
        }

        fun onValidateAuthBaseUrl(authBaseUrl: String) {
            this.authBaseUrl = authBaseUrl
            onFieldUpdated()
        }

        fun onValidateApiUrl(apiUrl: String) {
            this.apiUrl = apiUrl
            onFieldUpdated()
        }

        fun onValidateLogFilter(logFilter: String) {
            this.logFilter = logFilter
            onFieldUpdated()
        }

        fun createLogZip(context: Context) {
            viewModelScope.launch {
                val logDir = context.cacheDir.absolutePath + "/log"
                val sourceFolder = File(logDir)
                val zipFile = File("$logDir.zip")

                zipFolder(sourceFolder, zipFile).collect()

                val shareIntent =
                    Intent(Intent.ACTION_SEND).apply {
                        putExtra(
                            Intent.EXTRA_SUBJECT,
                            "Sharing diagnostic logs",
                        )

                        // Add additional details to the share intent, for ex: email body.
                        // putExtra(
                        //    Intent.EXTRA_TEXT,
                        //    "Sharing diagnostic logs for $input"
                        // )

                        val fileURI =
                            FileProvider.getUriForFile(
                                context,
                                "${context.applicationContext.packageName}.provider",
                                zipFile,
                            )
                        putExtra(Intent.EXTRA_STREAM, fileURI)

                        flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                        data = fileURI
                    }
                context.startActivity(shareIntent)
            }
        }

        private suspend fun zipFolder(
            sourceFolder: File,
            zipFile: File,
        ) = flow {
            ZipOutputStream(FileOutputStream(zipFile)).use { zipStream ->
                sourceFolder.walkTopDown().forEach { file ->
                    val entryName = sourceFolder.toPath().relativize(file.toPath()).toString()
                    if (file.isDirectory) {
                        zipStream.putNextEntry(ZipEntry("$entryName/"))
                        zipStream.closeEntry()
                    } else {
                        zipStream.putNextEntry(ZipEntry(entryName))
                        file.inputStream().use { input ->
                            input.copyTo(zipStream)
                        }
                        zipStream.closeEntry()
                    }
                    emit(Result.success(zipFile))
                }
            }
        }.catch { e ->
            emit(Result.failure(e))
        }.flowOn(Dispatchers.IO)

        private fun deleteLogZip(context: Context) {
            val logDir = context.cacheDir.absolutePath + "/log"
            val zipFile = File("$logDir.zip")
            if (zipFile.exists()) {
                zipFile.delete()
            }
        }

        private fun onFieldUpdated() {
            _uiState.value =
                _uiState.value.copy(
                    isSaveButtonEnabled = areFieldsValid(),
                )
        }

        private fun areFieldsValid(): Boolean {
            // This comes from the backend account slug validator at elixir/apps/domain/lib/domain/accounts/account/changeset.ex
            val accountIdRegex = Regex("^[a-z0-9_]{3,100}\$")
            return accountIdRegex.matches(accountId) &&
                URLUtil.isValidUrl(authBaseUrl) &&
                isUriValid(apiUrl) &&
                logFilter.isNotBlank()
        }

        private fun isUriValid(uri: String): Boolean {
            return try {
                URI(uri)
                true
            } catch (e: URISyntaxException) {
                false
            }
        }

        internal data class UiState(
            val isSaveButtonEnabled: Boolean = false,
            val logSize: Long = 0,
        )

        internal sealed class ViewAction {
            object NavigateBack : ViewAction()

            data class FillSettings(
                val accountId: String,
                val authBaseUrl: String,
                val apiUrl: String,
                val logFilter: String,
            ) : ViewAction()
        }
    }
