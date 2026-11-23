package com.benjaminissa.issareader.app.ui.signin

import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.model.SignInForm
import com.benjaminissa.issareader.core.networking.ServerAddress
import com.benjaminissa.issareader.ui.IssaTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.URI

/**
 * The sign-in form's plain-HTTP offer: shown only when there is one, worded
 * so the button itself says the address is not encrypted, and pressing it is
 * the only way it is taken.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], qualifiers = "w402dp-h1960dp-xxhdpi")
class SignInOfferViewTest {
    @get:Rule
    val compose = createComposeRule()

    private val offer = ServerAddress.CleartextOffer(
        tried = URI("https://storyteller.test"),
        offered = URI("http://storyteller.test:8001"),
    )

    private fun show(
        offer: ServerAddress.CleartextOffer?,
        connecting: Boolean = false,
        address: String = "https://storyteller.test",
        onContinue: () -> Unit = {},
        onDeviceCode: () -> Unit = {},
        onAccept: () -> Unit = {},
    ) = compose.setContent {
        IssaTheme(darkTheme = false) {
            ServerForm(
                address = address,
                onAddressChange = {},
                loadError = null,
                offer = offer,
                signInNote = null,
                connecting = connecting,
                onAcceptOffer = onAccept,
                onContinue = onContinue,
                onDeviceCode = onDeviceCode,
                onReadFromFiles = null,
            )
        }
    }

    @Test
    fun `the offer names both addresses and its button takes it`() {
        var taken = 0
        show(offer) { taken += 1 }

        compose.onNodeWithTag("text.cleartextOffer").assertExists()
        compose.onNodeWithText(SignInForm.offerText(offer)).assertExists()
        compose.onNodeWithText("Use http://storyteller.test:8001 (not encrypted)").assertExists()
        assertEquals("taken before it was pressed", 0, taken)

        compose.onNodeWithTag("button.useCleartext").performClick()

        assertEquals(1, taken)
    }

    /**
     * While the taken offer connects, the form is in the state Continue puts
     * it in: the bare address with its "Not encrypted" line, "Connecting…",
     * and nothing else to press, so no second press starts a browser or a
     * device code meanwhile.
     */
    @Test
    fun `while the offer connects nothing else can be pressed`() {
        var pressed = 0
        show(offer = null, connecting = true, address = "storyteller.test", onContinue = { pressed += 1 }, onDeviceCode = { pressed += 1 })

        compose.onNodeWithText("Not encrypted", substring = true).assertExists()
        compose.onNodeWithText("Connecting…").assertIsNotEnabled()
        compose.onNodeWithText("Use a device code").assertIsNotEnabled()
        compose.onNodeWithText("Connecting…").performClick()
        compose.onNodeWithText("Use a device code").performClick()
        assertEquals("a press went through while connecting", 0, pressed)
    }

    @Test
    fun `with no offer there is no button`() {
        show(null)
        assertEquals(0, compose.onAllNodesWithTag("button.useCleartext").fetchSemanticsNodes().size)
        assertEquals(0, compose.onAllNodesWithTag("text.cleartextOffer").fetchSemanticsNodes().size)
    }
}
