package com.androidbridge.update

import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.StringSpec
import io.kotest.matchers.booleans.shouldBeFalse
import io.kotest.matchers.nulls.shouldBeNull
import io.kotest.matchers.shouldBe
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking

class AndroidUpdateTest : StringSpec({
    "semantic versions are strict and compare numerically" {
        (SemanticVersion.parse("1.10.0") > SemanticVersion.parse("1.9.0")) shouldBe true
        listOf("1.02.0", "1.2", "v1.2.3", "1.2.3.0").forEach { shouldThrow<AndroidUpdateException.InvalidVersion> { SemanticVersion.parse(it) } }
    }

    "valid stable release and manifest decode" {
        val fixture = Fixture()
        val bundle = ReleaseBundleDecoder.decode(fixture.release(), fixture.manifest())
        bundle.version.toString() shouldBe "1.10.0"
        bundle.versionCode shouldBe 1_010_000
        bundle.android.name shouldBe fixture.apkName
    }

    "malformed nested assets map to update errors" {
        val fixture = Fixture()
        val malformed = fixture.release().replaceFirst(
            Regex("\\{\\\"name\\\":\\\"${Regex.escape(fixture.apkName)}\\\"[^}]+}"),
            "\"invalid asset\"",
        )
        shouldThrow<AndroidUpdateException.InvalidRelease> { ReleaseBundleDecoder.decode(malformed, fixture.manifest()) }
    }

    "release and manifest reject unsafe metadata" {
        val fixture = Fixture()
        val invalid = listOf(
            fixture.release().replace("\"draft\":false", "\"draft\":true"),
            fixture.release().replace("\"prerelease\":false", "\"prerelease\":true"),
            fixture.release().replace("\"tag_name\":\"v1.10.0\"", "\"tag_name\":\"latest-build\""),
            fixture.release().replace("\"tag_name\":\"v1.10.0\"", "\"tag_name\":\"v1.9.0\""),
            fixture.release().replace("\"assets\":[", "\"assets\":[{\"name\":\"${fixture.apkName}\",\"size\":3,\"browser_download_url\":\"https://github.com/iliagerman/android-bridge/releases/download/v1.10.0/${fixture.apkName}\"},"),
            fixture.release().replace("github.com/iliagerman", "example.com/iliagerman"),
        )
        invalid.forEach { shouldThrow<AndroidUpdateException> { ReleaseBundleDecoder.decode(it, fixture.manifest()) } }
        val invalidManifests = listOf(
            fixture.manifest().replace("\"android\":{", "\"extra\":true,\"android\":{"),
            fixture.manifest().replace("1010000", "1010001"),
            fixture.manifest().replace("\"minimumAndroidSdk\":33", "\"minimumAndroidSdk\":32"),
            fixture.manifest().replace(fixture.apkName, "AndroidBridge-1.10.0.apk"),
            fixture.manifest().replace("\"size\":3", "\"size\":4"),
            fixture.manifest().replace(fixture.hash, "A".repeat(64)),
            fixture.manifest().replace(fixture.signer, "B".repeat(64)),
        )
        invalidManifests.forEach { shouldThrow<AndroidUpdateException> { ReleaseBundleDecoder.decode(fixture.release(), it) } }
    }

    "only a release newer in both fields is an update" {
        val fixture = Fixture()
        val bundle = ReleaseBundleDecoder.decode(fixture.release(), fixture.manifest())
        val service = AndroidUpdateService(FakeReleaseSource(bundle), FakeDownloader(fixture), Files.createTempDirectory("updates").toFile())
        runBlocking {
            service.check("1.10.0", 1_010_000).shouldBeNull()
            service.check("1.11.0", 1_011_000).shouldBeNull()
            service.check("1.9.0", 1_009_000)?.bundle?.version shouldBe SemanticVersion.parse("1.10.0")
        }
    }

    "verified bytes require exact lowercase checksum and owned download path" {
        val fixture = Fixture()
        val bundle = ReleaseBundleDecoder.decode(fixture.release(), fixture.manifest())
        val root = Files.createTempDirectory("updates").toFile()
        val service = AndroidUpdateService(FakeReleaseSource(bundle), FakeDownloader(fixture), root)
        runBlocking {
            val downloaded = service.downloadAndVerify(AndroidUpdate(bundle))
            downloaded.file.readBytes() shouldBe fixture.bytes
            service.remove(downloaded)
        }
        listOf("${fixture.hash.uppercase()}  ${fixture.apkName}\n", "${fixture.hash} ${fixture.apkName}\n").forEach { checksum ->
            val failed = AndroidUpdateService(FakeReleaseSource(bundle), FakeDownloader(fixture, checksum = checksum), root)
            shouldThrow<AndroidUpdateException.ChecksumMismatch> { runBlocking { failed.downloadAndVerify(AndroidUpdate(bundle)) } }
        }
        val badBytes = AndroidUpdateService(FakeReleaseSource(bundle), FakeDownloader(fixture, bytes = byteArrayOf(1, 2)), root)
        shouldThrow<AndroidUpdateException.SizeMismatch> { runBlocking { badBytes.downloadAndVerify(AndroidUpdate(bundle)) } }
        val wrongHash = AndroidUpdateService(FakeReleaseSource(bundle), FakeDownloader(fixture, bytes = byteArrayOf(4, 5, 6)), root)
        shouldThrow<AndroidUpdateException.HashMismatch> { runBlocking { wrongHash.downloadAndVerify(AndroidUpdate(bundle)) } }
        val wrongName = AndroidUpdateService(FakeReleaseSource(bundle), FakeDownloader(fixture, returnedName = "renamed.apk"), root)
        shouldThrow<AndroidUpdateException.Storage> { runBlocking { wrongName.downloadAndVerify(AndroidUpdate(bundle)) } }
        (root.listFiles()?.filter { it.name.startsWith("android-bridge-update-") } ?: emptyList()).isEmpty() shouldBe true
        val outside = AndroidUpdateService(FakeReleaseSource(bundle), FakeDownloader(fixture, outside = true), root)
        shouldThrow<AndroidUpdateException.Storage> { runBlocking { outside.downloadAndVerify(AndroidUpdate(bundle)) } }
        (root.listFiles()?.filter { it.name.startsWith("android-bridge-update-") } ?: emptyList()).isEmpty() shouldBe true
    }
})

private class FakeReleaseSource(private val bundle: ReleaseBundle) : ReleaseSource {
    override suspend fun latestStableRelease(): ReleaseBundle = bundle
}

private class FakeDownloader(
    private val fixture: Fixture,
    private val checksum: String = "${fixture.hash}  ${fixture.apkName}\n",
    private val bytes: ByteArray = fixture.bytes,
    private val outside: Boolean = false,
    private val returnedName: String? = null,
) : ArtifactDownloader {
    override suspend fun text(asset: ReleaseAsset, maximumBytes: Long): String = checksum
    override suspend fun download(asset: ReleaseAsset, directory: File, maximumBytes: Long): File {
        val target = if (outside) File(directory.parentFile, "outside.apk") else File(directory, returnedName ?: asset.name)
        target.writeBytes(bytes)
        return target
    }
}

private class Fixture {
    val bytes = byteArrayOf(1, 2, 3)
    val hash = digest(bytes)
    val signer = "a".repeat(64)
    val version = "1.10.0"
    val apkName = "AndroidBridge-$version-android.apk"
    private val macName = "AndroidBridge-$version-macOS-arm64.dmg"
    private fun url(name: String) = "https://github.com/iliagerman/android-bridge/releases/download/v$version/$name"

    fun release() = """{"tag_name":"v$version","draft":false,"prerelease":false,"html_url":"https://github.com/iliagerman/android-bridge/releases/tag/v$version","assets":[
        {"name":"$apkName","size":3,"browser_download_url":"${url(apkName)}"},
        {"name":"$apkName.sha256","size":80,"browser_download_url":"${url("$apkName.sha256")}"},
        {"name":"$macName","size":3,"browser_download_url":"${url(macName)}"},
        {"name":"$macName.sha256","size":80,"browser_download_url":"${url("$macName.sha256")}"}
    ]}"""

    fun manifest() = """{"schemaVersion":1,"version":"$version","versionCode":1010000,"minimumMacOS":"13.0","minimumAndroidSdk":33,"macos":{"name":"$macName","size":3,"sha256":"$hash"},"android":{"name":"$apkName","size":3,"sha256":"$hash","signerSha256":"$signer"}}"""
}

private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
