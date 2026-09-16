package com.androidbridge.update

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.BufferedInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID

private val VERSION_PATTERN = Regex("(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)")
private val HASH_PATTERN = Regex("[0-9a-f]{64}")
private const val REPOSITORY = "iliagerman/android-bridge"
private const val RELEASE_API = "https://api.github.com/repos/$REPOSITORY/releases/latest"

class SemanticVersion private constructor(
    val major: Int,
    val minor: Int,
    val patch: Int,
) : Comparable<SemanticVersion> {
    override fun compareTo(other: SemanticVersion): Int = compareValuesBy(this, other, SemanticVersion::major, SemanticVersion::minor, SemanticVersion::patch)
    override fun equals(other: Any?): Boolean = other is SemanticVersion && compareTo(other) == 0
    override fun hashCode(): Int = arrayOf(major, minor, patch).contentHashCode()
    override fun toString(): String = "$major.$minor.$patch"

    companion object {
        fun parse(value: String): SemanticVersion {
            val match = VERSION_PATTERN.matchEntire(value) ?: throw AndroidUpdateException.InvalidVersion
            val parts = match.groupValues.drop(1).map { it.toLongOrNull() ?: throw AndroidUpdateException.InvalidVersion }
            if (parts[0] > 2_100 || parts[1] > 999 || parts[2] > 999) throw AndroidUpdateException.InvalidVersion
            return SemanticVersion(parts[0].toInt(), parts[1].toInt(), parts[2].toInt())
        }
    }
}

data class ReleaseAsset(val name: String, val size: Long, val url: String)
data class ReleaseBundle(
    val version: SemanticVersion,
    val versionCode: Int,
    val releasePage: String,
    val android: ReleaseAsset,
    val checksum: ReleaseAsset,
    val signerSha256: String,
    val sha256: String,
)
data class AndroidUpdate(val bundle: ReleaseBundle)
class DownloadedApk internal constructor(val file: File, internal val directory: File)

sealed class AndroidUpdateException(message: String) : Exception(message) {
    data object InvalidVersion : AndroidUpdateException("Update metadata has an invalid version.")
    data object InvalidRelease : AndroidUpdateException("Update metadata is invalid.")
    data object InvalidManifest : AndroidUpdateException("Update manifest is invalid.")
    data object UnsafeUrl : AndroidUpdateException("Update download location is invalid.")
    data object Network : AndroidUpdateException("Could not contact the update service.")
    data object ResponseTooLarge : AndroidUpdateException("Update response is too large.")
    data object ChecksumMismatch : AndroidUpdateException("Update checksum verification failed.")
    data object SizeMismatch : AndroidUpdateException("Update file size verification failed.")
    data object HashMismatch : AndroidUpdateException("Update file verification failed.")
    data object Storage : AndroidUpdateException("Could not prepare update storage.")
    data object Cleanup : AndroidUpdateException("Could not clean temporary update files.")
    data object Signature : AndroidUpdateException("Update signature verification failed.")
    data object Installer : AndroidUpdateException("Could not open the system installer.")
}

interface ReleaseSource { suspend fun latestStableRelease(): ReleaseBundle }
interface ArtifactDownloader {
    suspend fun text(asset: ReleaseAsset, maximumBytes: Long): String
    suspend fun download(asset: ReleaseAsset, directory: File, maximumBytes: Long): File
}

internal object ReleaseBundleDecoder {
    private val json = Json { ignoreUnknownKeys = false }

    fun decode(releaseJson: String, manifestJson: String): ReleaseBundle = try {
        val release = parseObject(releaseJson, AndroidUpdateException.InvalidRelease)
        val manifest = parseObject(manifestJson, AndroidUpdateException.InvalidManifest)
        val version = manifestVersion(manifest)
        val assets = releaseAssets(release)
        validateMacAssets(manifest, version, assets)
        val android = androidDescriptor(manifest, version, assets)
        val checksum = requiredAsset(assets, "${android.first.name}.sha256", version)
        validateRelease(release, version)
        ReleaseBundle(version, versionCode(manifest, version), releasePage(release, version), android.first, checksum, android.second, android.third)
    } catch (error: AndroidUpdateException) {
        throw error
    } catch (_: SerializationException) {
        throw AndroidUpdateException.InvalidRelease
    } catch (_: IllegalArgumentException) {
        throw AndroidUpdateException.InvalidRelease
    } catch (_: IllegalStateException) {
        throw AndroidUpdateException.InvalidRelease
    }

    private fun manifestVersion(manifest: JsonObject): SemanticVersion {
        requireKeys(manifest, setOf("schemaVersion", "version", "versionCode", "minimumMacOS", "minimumAndroidSdk", "macos", "android"), AndroidUpdateException.InvalidManifest)
        if (integer(manifest, "schemaVersion") != 1L || string(manifest, "minimumMacOS") != "13.0" || integer(manifest, "minimumAndroidSdk") != 33L) throw AndroidUpdateException.InvalidManifest
        validateMac(manifest["macos"]?.jsonObject ?: throw AndroidUpdateException.InvalidManifest, string(manifest, "version"))
        return SemanticVersion.parse(string(manifest, "version"))
    }

    private fun versionCode(manifest: JsonObject, version: SemanticVersion): Int {
        val code = integer(manifest, "versionCode")
        val expected = version.major * 1_000_000L + version.minor * 1_000L + version.patch
        if (code != expected || code !in 1..2_100_000_000) throw AndroidUpdateException.InvalidManifest
        return code.toInt()
    }

    private fun validateMac(macos: JsonObject, version: String) {
        requireKeys(macos, setOf("name", "size", "sha256"), AndroidUpdateException.InvalidManifest)
        if (string(macos, "name") != "AndroidBridge-$version-macOS-arm64.dmg" || integer(macos, "size") <= 0 || !isHash(string(macos, "sha256"))) throw AndroidUpdateException.InvalidManifest
    }

    private fun validateMacAssets(manifest: JsonObject, version: SemanticVersion, assets: Map<String, ReleaseAsset>) {
        val macos = manifest["macos"]?.jsonObject ?: throw AndroidUpdateException.InvalidManifest
        val name = string(macos, "name")
        val asset = requiredAsset(assets, name, version)
        if (asset.size != integer(macos, "size")) throw AndroidUpdateException.InvalidManifest
        requiredAsset(assets, "$name.sha256", version)
    }

    private fun androidDescriptor(manifest: JsonObject, version: SemanticVersion, assets: Map<String, ReleaseAsset>): Triple<ReleaseAsset, String, String> {
        val android = manifest["android"]?.jsonObject ?: throw AndroidUpdateException.InvalidManifest
        requireKeys(android, setOf("name", "size", "sha256", "signerSha256"), AndroidUpdateException.InvalidManifest)
        val name = string(android, "name")
        val size = integer(android, "size")
        val hash = string(android, "sha256")
        val signer = string(android, "signerSha256")
        if (name != "AndroidBridge-$version-android.apk" || size <= 0 || !isHash(hash) || !isHash(signer)) throw AndroidUpdateException.InvalidManifest
        val asset = requiredAsset(assets, name, version)
        if (asset.size != size) throw AndroidUpdateException.InvalidManifest
        return Triple(asset, signer, hash)
    }

    private fun validateRelease(release: JsonObject, version: SemanticVersion) {
        if (string(release, "tag_name") != "v$version" || boolean(release, "draft") || boolean(release, "prerelease")) throw AndroidUpdateException.InvalidRelease
    }

    private fun releasePage(release: JsonObject, version: SemanticVersion): String {
        val page = string(release, "html_url")
        val expected = "https://github.com/$REPOSITORY/releases/tag/v$version"
        if (page != expected) throw AndroidUpdateException.InvalidRelease
        return page
    }

    private fun releaseAssets(release: JsonObject): Map<String, ReleaseAsset> {
        val items = release["assets"]?.jsonArray ?: throw AndroidUpdateException.InvalidRelease
        val assets = items.map { asset(it.jsonObject) }
        if (assets.map { it.name }.toSet().size != assets.size) throw AndroidUpdateException.InvalidRelease
        return assets.associateBy { it.name }
    }

    private fun asset(value: JsonObject): ReleaseAsset {
        val name = string(value, "name")
        val size = integer(value, "size")
        val url = string(value, "browser_download_url")
        if (name.isEmpty() || size <= 0) throw AndroidUpdateException.InvalidRelease
        return ReleaseAsset(name, size, url)
    }

    private fun requiredAsset(assets: Map<String, ReleaseAsset>, name: String, version: SemanticVersion): ReleaseAsset {
        val asset = assets[name] ?: throw AndroidUpdateException.InvalidRelease
        val expected = "https://github.com/$REPOSITORY/releases/download/v$version/$name"
        if (asset.url != expected) throw AndroidUpdateException.InvalidRelease
        return asset
    }

    private fun parseObject(text: String, error: AndroidUpdateException): JsonObject = try {
        json.parseToJsonElement(text).jsonObject
    } catch (_: Exception) { throw error }

    private fun requireKeys(value: JsonObject, expected: Set<String>, error: AndroidUpdateException) {
        if (value.keys != expected) throw error
    }

    private fun string(value: JsonObject, key: String): String {
        val primitive = value[key]?.jsonPrimitive ?: throw AndroidUpdateException.InvalidManifest
        if (!primitive.isString) throw AndroidUpdateException.InvalidManifest
        return primitive.content
    }

    private fun integer(value: JsonObject, key: String): Long {
        val primitive = value[key]?.jsonPrimitive ?: throw AndroidUpdateException.InvalidManifest
        if (primitive.isString) throw AndroidUpdateException.InvalidManifest
        return primitive.content.toLongOrNull() ?: throw AndroidUpdateException.InvalidManifest
    }

    private fun boolean(value: JsonObject, key: String): Boolean {
        val primitive = value[key]?.jsonPrimitive ?: throw AndroidUpdateException.InvalidRelease
        if (primitive.isString) throw AndroidUpdateException.InvalidRelease
        return primitive.content.toBooleanStrictOrNull() ?: throw AndroidUpdateException.InvalidRelease
    }
    private fun isHash(value: String): Boolean = HASH_PATTERN.matches(value)
}

class GitHubReleaseSource : ReleaseSource {
    override suspend fun latestStableRelease(): ReleaseBundle = withContext(Dispatchers.IO) {
        try {
            val release = GitHubHttp.get(RELEASE_API, 1_048_576, GitHubHttp::apiUrl)
            val manifestAsset = releaseManifestAsset(release)
            val manifest = GitHubHttp.get(manifestAsset.url, 65_536, GitHubHttp::releaseAssetUrl)
            ReleaseBundleDecoder.decode(release, manifest)
        } catch (error: AndroidUpdateException) {
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw AndroidUpdateException.InvalidRelease
        }
    }

    private fun releaseManifestAsset(release: String): ReleaseAsset {
        val objectValue = try { Json.parseToJsonElement(release).jsonObject } catch (_: Exception) { throw AndroidUpdateException.InvalidRelease }
        val tag = objectValue["tag_name"]?.jsonPrimitive?.content ?: throw AndroidUpdateException.InvalidRelease
        val version = SemanticVersion.parse(tag.removePrefix("v"))
        val page = objectValue["html_url"]?.jsonPrimitive?.content ?: throw AndroidUpdateException.InvalidRelease
        val draft = objectValue["draft"]?.jsonPrimitive?.content?.toBooleanStrictOrNull()
        val prerelease = objectValue["prerelease"]?.jsonPrimitive?.content?.toBooleanStrictOrNull()
        if (tag != "v$version" || page != "https://github.com/$REPOSITORY/releases/tag/v$version" || draft != false || prerelease != false) throw AndroidUpdateException.InvalidRelease
        val assets = objectValue["assets"]?.jsonArray ?: throw AndroidUpdateException.InvalidRelease
        val matches = assets.map { it.jsonObject }.filter { it["name"]?.jsonPrimitive?.content == "release-manifest.json" }
        if (matches.size != 1) throw AndroidUpdateException.InvalidRelease
        val value = matches.single()
        val size = value["size"]?.jsonPrimitive?.content?.toLongOrNull() ?: throw AndroidUpdateException.InvalidRelease
        val url = value["browser_download_url"]?.jsonPrimitive?.content ?: throw AndroidUpdateException.InvalidRelease
        val expected = "https://github.com/$REPOSITORY/releases/download/v$version/release-manifest.json"
        if (size !in 1..65_536 || url != expected) throw AndroidUpdateException.InvalidRelease
        return ReleaseAsset("release-manifest.json", size, url)
    }
}

class HttpArtifactDownloader : ArtifactDownloader {
    override suspend fun text(asset: ReleaseAsset, maximumBytes: Long): String = withContext(Dispatchers.IO) {
        GitHubHttp.get(asset.url, maximumBytes, GitHubHttp::releaseAssetUrl)
    }

    override suspend fun download(asset: ReleaseAsset, directory: File, maximumBytes: Long): File = withContext(Dispatchers.IO) {
        val target = File(directory, asset.name)
        try {
            if (maximumBytes <= 0 || !directory.isDirectory) throw AndroidUpdateException.Storage
            if (target.parentFile?.canonicalFile != directory.canonicalFile || !target.createNewFile()) throw AndroidUpdateException.Storage
            GitHubHttp.download(asset.url, target, maximumBytes, GitHubHttp::releaseAssetUrl)
            target
        } catch (error: AndroidUpdateException) {
            target.delete()
            throw error
        } catch (_: java.io.IOException) {
            target.delete()
            throw AndroidUpdateException.Storage
        }
    }
}

private object GitHubHttp {
    private val redirectHosts = setOf("api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com")

    fun apiUrl(value: String): Boolean = value == RELEASE_API
    fun releaseAssetUrl(value: String): Boolean = clean(value, redirectHosts)

    fun get(initial: String, maximum: Long, validator: (String) -> Boolean): String = try {
        val connection = open(initial, validator)
        connection.inputStream.use { readBounded(it, maximum).toString(Charsets.UTF_8) }
    } catch (error: AndroidUpdateException) { throw error
    } catch (_: java.io.IOException) { throw AndroidUpdateException.Network }

    fun download(initial: String, destination: File, maximum: Long, validator: (String) -> Boolean) = try {
        val connection = open(initial, validator)
        connection.inputStream.use { input -> destination.outputStream().buffered().use { output -> copyBounded(input, output, maximum) } }
    } catch (error: AndroidUpdateException) { throw error
    } catch (_: java.io.IOException) { throw AndroidUpdateException.Network }

    private fun open(initial: String, validator: (String) -> Boolean): HttpURLConnection {
        if (!validator(initial)) throw AndroidUpdateException.UnsafeUrl
        var current = initial
        repeat(6) { hop ->
            val connection = (URL(current).openConnection() as HttpURLConnection).apply { instanceFollowRedirects = false; connectTimeout = 15_000; readTimeout = 30_000 }
            when (connection.responseCode) {
                HttpURLConnection.HTTP_OK -> return connection
                in 300..399 -> {
                    if (hop == 5) throw AndroidUpdateException.Network
                    val location = connection.getHeaderField("Location") ?: throw AndroidUpdateException.Network
                    current = URL(URL(current), location).toString()
                    connection.disconnect()
                    if (!clean(current, redirectHosts)) throw AndroidUpdateException.UnsafeUrl
                }
                else -> { connection.disconnect(); throw AndroidUpdateException.Network }
            }
        }
        throw AndroidUpdateException.Network
    }

    private fun readBounded(input: java.io.InputStream, maximum: Long): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        copyBounded(input, output, maximum)
        return output.toByteArray()
    }

    private fun copyBounded(input: java.io.InputStream, output: java.io.OutputStream, maximum: Long) {
        if (maximum <= 0) throw AndroidUpdateException.ResponseTooLarge
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0L
        BufferedInputStream(input).use { source -> while (true) {
            val allowed = (maximum - total + 1).coerceAtMost(buffer.size.toLong()).toInt()
            val count = source.read(buffer, 0, allowed)
            if (count < 0) return
            total += count
            if (total > maximum) throw AndroidUpdateException.ResponseTooLarge
            output.write(buffer, 0, count)
        } }
    }

    private fun clean(value: String, hosts: Set<String>): Boolean = try {
        val url = URL(value)
        url.protocol == "https" && url.host in hosts && url.port == -1 && url.userInfo == null && url.ref == null
    } catch (_: Exception) { false }
}

class AndroidUpdateService(
    private val releases: ReleaseSource,
    private val downloader: ArtifactDownloader,
    private val cacheRoot: File,
) {
    suspend fun check(currentVersionName: String, currentVersionCode: Int): AndroidUpdate? = withContext(Dispatchers.IO) {
        val current = SemanticVersion.parse(currentVersionName)
        if (versionCodeFor(current) != currentVersionCode) throw AndroidUpdateException.InvalidVersion
        val release = releases.latestStableRelease()
        if (release.version > current && release.versionCode > currentVersionCode) AndroidUpdate(release) else null
    }

    suspend fun downloadAndVerify(update: AndroidUpdate): DownloadedApk = withContext(Dispatchers.IO) {
        val directory = createDirectory()
        try {
            val checksum = downloader.text(update.bundle.checksum, 256)
            verifyChecksum(checksum, update.bundle)
            val file = downloader.download(update.bundle.android, directory, update.bundle.android.size)
            verifyFile(file, directory, update.bundle)
            DownloadedApk(file, directory)
        } catch (error: CancellationException) {
            removeDirectory(directory)
            throw error
        } catch (error: AndroidUpdateException) {
            removeDirectory(directory)
            throw error
        } catch (_: Exception) {
            removeDirectory(directory)
            throw AndroidUpdateException.Storage
        }
    }

    fun cleanTemporaryUpdates() {
        if (!cacheRoot.exists()) return
        cacheRoot.listFiles()?.filter { it.name.startsWith("android-bridge-update-") }?.forEach(::removeDirectory)
            ?: throw AndroidUpdateException.Cleanup
    }

    fun remove(download: DownloadedApk) {
        if (!download.directory.name.startsWith("android-bridge-update-") || download.directory.parentFile?.canonicalFile != cacheRoot.canonicalFile) throw AndroidUpdateException.Storage
        removeDirectory(download.directory)
    }

    private fun createDirectory(): File {
        if (!cacheRoot.exists() && !cacheRoot.mkdirs() || !cacheRoot.isDirectory) throw AndroidUpdateException.Storage
        val directory = File(cacheRoot, "android-bridge-update-${UUID.randomUUID()}")
        if (!directory.mkdir()) throw AndroidUpdateException.Storage
        return directory
    }

    private fun verifyChecksum(value: String, bundle: ReleaseBundle) {
        if (value != "${bundle.sha256}  ${bundle.android.name}\n") throw AndroidUpdateException.ChecksumMismatch
    }

    private fun verifyFile(file: File, directory: File, bundle: ReleaseBundle) {
        if (file.canonicalFile.parentFile != directory.canonicalFile || file.name != bundle.android.name) throw AndroidUpdateException.Storage
        if (file.length() != bundle.android.size) throw AndroidUpdateException.SizeMismatch
        if (sha256(file) != bundle.sha256) throw AndroidUpdateException.HashMismatch
    }

    private fun removeDirectory(directory: File) {
        try {
            if (!directory.exists()) return
            directory.walkBottomUp().forEach { if (!it.delete()) throw AndroidUpdateException.Cleanup }
        } catch (error: AndroidUpdateException) {
            throw error
        } catch (_: SecurityException) {
            throw AndroidUpdateException.Cleanup
        }
    }

    private fun versionCodeFor(version: SemanticVersion): Int = version.major * 1_000_000 + version.minor * 1_000 + version.patch
}

private fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}
