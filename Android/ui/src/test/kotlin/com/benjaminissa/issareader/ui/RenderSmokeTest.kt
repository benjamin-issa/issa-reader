package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.core.app.ApplicationProvider
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RenderSmokeTest {
    @Test
    fun rendersBundledSerif() {
        val assets = ApplicationProvider.getApplicationContext<android.content.Context>().assets
        val literata = FontFamily(Font("Fonts/Literata-Regular.ttf", assets))
        captureRoboImage("build/smoke/literata.png") {
            Box(Modifier.size(320.dp, 120.dp).background(Color(0xFFFFFDF8)).padding(16.dp)) {
                Text("All children, except one, grow up.", style = TextStyle(fontFamily = literata, fontSize = 18.sp, color = Color(0xFF221F1A)))
            }
        }
    }
}
