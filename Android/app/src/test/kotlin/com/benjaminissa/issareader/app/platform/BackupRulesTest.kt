package com.benjaminissa.issareader.app.platform

import android.content.Context
import android.content.pm.ApplicationInfo
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.xmlpull.v1.XmlPullParser
import com.benjaminissa.issareader.R
import java.io.File

/**
 * What Android backs up is the same on Android 11 as on Android 12 and later.
 *
 * Android 12 reads `data_extraction_rules.xml` and Android 11 reads only
 * `backup_rules.xml`, so the app needs both; the minimum went down to Android
 * 11 for the first Boox Palma, and with only the newer file that phone backed
 * up downloads and the diagnostics log. Both must name the same paths, or
 * PRIVACY-ANDROID.md is true on one generation and not the other.
 */
@RunWith(RobolectricTestRunner::class)
class BackupRulesTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    /** Every `<include>` in [resource], as domain/path, under whichever section it sits. */
    private fun includes(resource: Int): Map<String, Set<String>> {
        val parser = context.resources.getXml(resource)
        val sections = mutableMapOf<String, MutableSet<String>>()
        var section = ""
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType != XmlPullParser.START_TAG) continue
            when (parser.name) {
                "cloud-backup", "device-transfer", "full-backup-content" -> section = parser.name
                "include" -> sections.getOrPut(section) { mutableSetOf() } +=
                    "${parser.getAttributeValue(null, "domain")}/${parser.getAttributeValue(null, "path")}"
            }
        }
        return sections
    }

    @Test
    fun `Android 11's rules include what Android 12's do, and nothing else`() {
        val newer = includes(R.xml.data_extraction_rules)
        val older = includes(R.xml.backup_rules)
        val expected = setOf("sharedpref/.", "file/datastore/", "file/Store/")
        assertEquals(expected, newer["cloud-backup"])
        assertEquals(expected, newer["device-transfer"])
        assertEquals("Android 11 backs up something else", expected, older["full-backup-content"])
    }

    /** Read from the source: the attribute the older rules hang on is not one Android's API exposes. */
    @Test
    fun `the manifest names both`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue("backups are on", context.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP != 0)
        assertTrue(manifest.contains("""android:dataExtractionRules="@xml/data_extraction_rules""""))
        assertTrue(manifest.contains("""android:fullBackupContent="@xml/backup_rules""""))
    }
}
