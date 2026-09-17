package com.discflightschool.core.posture

import com.discflightschool.core.baseline.ProBaselineDatabase
import com.discflightschool.core.model.FormFrame
import com.discflightschool.core.model.ThrowTypes
import java.util.Locale
import kotlin.math.abs

/** One coaching suggestion, optionally linked to a knowledge base article. */
data class FormSuggestion(val text: String, val kbArticleId: String? = null)

/**
 * Turns measured deviations from pro data into coaching cues.
 *
 * Suggestions are specific where the data allows: "Your elbow at power pocket
 * (94.0°) is straighter than Wysocki (71.6°) — tuck the disc tighter during the
 * pull for more power." Where no pro is selected, the cross-player baseline
 * mean stands in.
 */
object FormSuggestions {

    /**
     * Generate suggestions for an analysis.
     *
     * [proPhaseAngles] is the selected pro's per-phase angles, if any;
     * [phaseFrameIndices] maps phase names to the frames the user marked them
     * at. Only deviations beyond one standard deviation are flagged.
     */
    fun generate(
        frames: List<FormFrame>,
        baseline: ProBaselineDatabase?,
        throwType: String = ThrowTypes.BACKHAND,
        proPhaseAngles: Map<String, Map<String, Double>>? = null,
        phaseFrameIndices: Map<String, Int>? = null,
        proName: String? = null,
    ): List<FormSuggestion> {
        if (frames.isEmpty() || baseline == null) return genericSuggestions(throwType)

        val summary = baseline.baselineSummary(throwType)
        val userPhaseAngles =
            PostureMath.extractUserPhaseAngles(frames, throwType, phaseFrameIndices)

        val suggestions = ArrayList<FormSuggestion>()

        for (phaseName in ProBaselineDatabase.phaseNames(throwType)) {
            val userAngles = userPhaseAngles[phaseName] ?: continue
            val proAngles = proPhaseAngles?.get(phaseName)
            val phaseStats = summary[phaseName] ?: continue

            for ((appKey, userAngle) in userAngles) {
                val jsonKey = PostureMath.reverseAngleKey(appKey, throwType)
                val stats = jsonKey?.let { phaseStats[it] }

                var refAngle: Double?
                val refSD: Double?
                val refLabel: String

                if (proAngles != null && proAngles[appKey] != null) {
                    refAngle = proAngles.getValue(appKey)
                    refLabel = proName ?: "pro"
                    // The SD still comes from the baseline, even when comparing
                    // against one specific pro.
                    refSD = stats?.get("sd")
                } else {
                    if (stats == null) continue
                    refAngle = stats["mean"]
                    refSD = stats["sd"]
                    refLabel = "pro average"
                    // Convert from the JSON convention to the app's.
                    if (jsonKey == "trunk_lateral_tilt_deg" && refAngle != null) {
                        refAngle = 90.0 - refAngle
                    }
                }

                if (refAngle == null || refSD == null || refSD == 0.0) continue
                val deviationSD = (userAngle - refAngle) / refSD

                // Only flag deviations beyond one standard deviation.
                if (abs(deviationSD) <= 1.0) continue

                suggestionForAngle(
                    appKey = appKey,
                    phaseName = phaseName,
                    throwType = throwType,
                    userAngle = userAngle,
                    refAngle = refAngle,
                    refLabel = refLabel,
                    deviationSD = deviationSD,
                )?.let { suggestions += it }
            }
        }

        return suggestions.ifEmpty { positiveSuggestions() }
    }

    /** Build a specific coaching suggestion for one angle deviation. */
    fun suggestionForAngle(
        appKey: String,
        phaseName: String,
        throwType: String,
        userAngle: Double,
        refAngle: Double,
        refLabel: String,
        deviationSD: Double,
    ): FormSuggestion? {
        val phaseLabel = phaseName.replace('_', ' ')
        val user = format1(userAngle)
        val ref = format1(refAngle)
        val direction = if (deviationSD > 0) "above" else "below"

        return when (appKey) {
            "rightElbowAngle" -> if (throwType == ThrowTypes.FOREHAND) {
                if (deviationSD > 1) {
                    FormSuggestion(
                        "Your throwing elbow at $phaseLabel ($user°) is straighter than " +
                            "$refLabel ($ref°) — keep more bend to maximise forehand snap",
                        kbArticleId = "bio_tip_1",
                    )
                } else {
                    FormSuggestion(
                        "Your elbow at $phaseLabel ($user°) is more bent than $refLabel " +
                            "($ref°) — extend slightly to increase leverage at release",
                        kbArticleId = "bio_tip_1",
                    )
                }
            } else {
                if (deviationSD > 1) {
                    FormSuggestion(
                        "Your elbow at $phaseLabel ($user°) is straighter than $refLabel " +
                            "($ref°) — tuck the disc tighter during the pull for more power",
                        kbArticleId = "bio_tip_1",
                    )
                } else {
                    FormSuggestion(
                        "Your elbow at $phaseLabel ($user°) is more bent than $refLabel " +
                            "($ref°) — extend fully toward the target at release",
                        kbArticleId = "bio_tip_1",
                    )
                }
            }

            "rightShoulderAngle" -> if (deviationSD < -1) {
                FormSuggestion(
                    "Your throwing shoulder at $phaseLabel ($user°) is $direction the " +
                        "$refLabel range ($ref°) — increase shoulder rotation for more disc speed",
                    kbArticleId = "bio_tip_3",
                )
            } else {
                FormSuggestion(
                    "Your throwing shoulder at $phaseLabel ($user°) is $direction the " +
                        "$refLabel range ($ref°) — keep the shoulder more closed until the power pocket",
                    kbArticleId = "bio_tip_3",
                )
            }

            "rightKneeAngle", "leftKneeAngle" -> {
                val side = PostureMath.kneeSideLabel(appKey, throwType) ?: return null
                val cue = if (deviationSD < -1) {
                    "bend more to load the legs for power"
                } else {
                    "straighten to drive through the throw"
                }
                FormSuggestion(
                    "Your $side knee at $phaseLabel ($user°) is $direction the $refLabel " +
                        "range ($ref°) — $cue",
                    kbArticleId = "bio_faq_4",
                )
            }

            "spineAngle" -> {
                val cue = if (deviationSD < -1) {
                    "stay taller through the throw to keep accuracy"
                } else {
                    "lean slightly into the throw for power"
                }
                FormSuggestion(
                    "Your trunk lean at $phaseLabel ($user°) is $direction the $refLabel " +
                        "range ($ref°) — $cue",
                    kbArticleId = "bio_tip_4",
                )
            }

            "xFactor" -> if (deviationSD < -1) {
                FormSuggestion(
                    "Your hip-shoulder separation at $phaseLabel ($user°) is below " +
                        "$refLabel ($ref°) — rotate the hips further ahead of the shoulders " +
                        "in the backswing",
                    kbArticleId = "bio_tip_5",
                )
            } else {
                null
            }

            "leftElbowAngle" -> if (throwType == ThrowTypes.BACKHAND && deviationSD < -1) {
                FormSuggestion(
                    "Your off-arm at $phaseLabel ($user°) is more bent than $refLabel " +
                        "($ref°) — extend the off-arm to help maintain shoulder plane",
                )
            } else {
                null
            }

            else -> null
        }
    }

    fun genericSuggestions(throwType: String): List<FormSuggestion> = listOf(
        FormSuggestion("Upload a video to get personalized form suggestions"),
        FormSuggestion("Focus on maintaining balance throughout your throw"),
        FormSuggestion(
            if (throwType == ThrowTypes.FOREHAND) {
                "Practice your forehand sidearm snap"
            } else {
                "Practice your reach-back motion"
            },
            kbArticleId = "bio_faq_2",
        ),
    )

    fun positiveSuggestions(): List<FormSuggestion> = listOf(
        FormSuggestion("Your angles are within the pro range — great form!"),
        FormSuggestion("Focus on smooth, controlled movements"),
        FormSuggestion("Try recording from different angles for a fuller picture"),
    )

    private fun format1(value: Double) = String.format(Locale.US, "%.1f", value)
}
