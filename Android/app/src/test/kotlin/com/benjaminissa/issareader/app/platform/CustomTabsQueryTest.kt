package com.benjaminissa.issareader.app.platform

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The browser sign-in can see the browsers on the phone.
 *
 * From Android 11 an app sees only the packages its manifest names, and
 * `CustomTabsClient.getPackageName` finds a browser by asking for services
 * with the Custom Tabs action. Without that query it finds none, and the
 * sign-in never offers the browser. Package visibility is not enforced under
 * Robolectric, so this reads the source manifest itself.
 */
class CustomTabsQueryTest {
    @Test
    fun `the manifest queries for Custom Tabs services`() {
        val manifest = listOf("src/main/AndroidManifest.xml", "app/src/main/AndroidManifest.xml")
            .map(::File).first { it.isFile }
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(manifest)
        val actions = document.getElementsByTagName("queries").item(0).let { queries ->
            val found = (queries as org.w3c.dom.Element).getElementsByTagName("action")
            (0 until found.length).map { (found.item(it) as org.w3c.dom.Element).getAttribute("android:name") }
        }
        assertTrue(actions.toString(), "android.support.customtabs.action.CustomTabsService" in actions)
    }
}
