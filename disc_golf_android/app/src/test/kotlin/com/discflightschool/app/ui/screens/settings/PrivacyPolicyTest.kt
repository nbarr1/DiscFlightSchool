package com.discflightschool.app.ui.screens.settings

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class PrivacyPolicyTest {
    /**
     * The hosted policy is what Google Play links to, and the in-app screen is
     * what users read. They must say the same thing.
     */
    @Test
    fun `the hosted policy matches the in-app policy`() {
        val expected = buildString {
            appendLine("# Disc Flight School privacy policy")
            appendLine()
            appendLine("Last updated: ${PrivacyPolicy.LAST_UPDATED}")
            appendLine()
            appendLine(PrivacyPolicy.INTRO)
            for (section in PrivacyPolicy.SECTIONS) {
                appendLine()
                appendLine("## ${section.title}")
                appendLine()
                appendLine(section.body)
            }
        }

        assertEquals(expected, hostedPolicy().readText())
    }

    /** Unit tests run from the module directory, `disc_golf_android/app`. */
    private fun hostedPolicy(): File =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "docs/privacy-policy.md") }
            .first { it.isFile }
}
