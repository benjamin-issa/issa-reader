package com.benjaminissa.issareader.ask.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * The regression questions, asked repeatedly and recorded rather than
 * asserted — IssaAsk's `AskScorecardTests`.
 *
 * A new model version is compared by recording what the shipped prompt
 * produces, changing it, and comparing — over more than one run, because the
 * model is not deterministic across versions even when it is within one. One
 * JSON line per ask, to a file named by the `ISSA_ASK_SCORECARD` argument,
 * which is also the switch: without it the suite is skipped.
 *
 *     ./gradlew :ask-android:connectedDebugAndroidTest \
 *         -Pandroid.testInstrumentationRunnerArguments.class=com.benjaminissa.issareader.ask.android.AskScorecardTest \
 *         -Pandroid.testInstrumentationRunnerArguments.ISSA_ASK_SCORECARD=v1
 *
 * `ISSA_ASK_SCORECARD_RUNS` (default 5) and `ISSA_ASK_SCORECARD_DIR` (default
 * the app's cache) are the other two knobs. The file is the artefact; the test
 * fails only if a question cannot be asked at all.
 */
@RunWith(AndroidJUnit4::class)
class AskScorecardTest {
    private val label: String? get() = Device.argument("ISSA_ASK_SCORECARD")
    private val runs: Int get() = maxOf(1, Device.argument("ISSA_ASK_SCORECARD_RUNS")?.toIntOrNull() ?: 5)
    private val directory: File get() = Device.argument("ISSA_ASK_SCORECARD_DIR")?.let(::File) ?: Device.scratch

    @Test
    fun everyFixtureQuestionSeveralTimesOnTheRecord() = runBlocking {
        val label = label
        assumeTrue("ISSA_ASK_SCORECARD is not set", label != null)
        assumeTrue("Gemini Nano is not available", GeminiNanoAnswerModel.isAvailableForTesting())
        label!!
        val file = File(directory, "ask-scorecard-$label.jsonl")
        // Appended, never truncated: a second invocation must not destroy the
        // first one's measurements.
        file.parentFile?.mkdirs()
        val json = Json { encodeDefaults = true }

        var passed = 0
        var total = 0
        for ((book, questions) in QuestionFixture.books()) {
            val run = RegressionRun.start(book)
            try {
                for (fixture in QuestionFixture.all(questions)) {
                    for (index in 1..runs) {
                        val outcome = run.ask(fixture)
                        val fields = json.encodeToJsonElement(RegressionRun.Outcome.serializer(), outcome).jsonObject.toMutableMap()
                        fields["label"] = JsonPrimitive(label)
                        fields["run"] = JsonPrimitive(index)
                        fields["passes"] = JsonPrimitive(outcome.passes)
                        file.appendText(JsonObject(fields.toSortedMap()).toString() + "\n")
                        total += 1
                        if (outcome.passes) passed += 1
                    }
                }
            } finally {
                run.tearDown()
            }
        }
        println("[scorecard] $label: $passed/$total passed — ${file.path}")
    }
}
