package com.discflightschool.app.ui.screens.roulette

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.FlashOn
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Scoreboard
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.discflightschool.app.LocalAppContainer
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.components.LabeledRow
import com.discflightschool.app.ui.components.SectionCard
import com.discflightschool.app.ui.theme.AppColors
import com.discflightschool.core.model.DiscLists
import com.discflightschool.core.model.Hindrance
import com.discflightschool.core.model.RouletteResult
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.launch

/**
 * Spins a random challenge: a shot shape, a disc, a power level, and something
 * to make it harder.
 *
 * Putting mode swaps the hindrance for a putt style and narrows the disc list,
 * because a turbo putt with a distance driver is a different game entirely.
 */
@Composable
fun RouletteScreen(
    onBack: () -> Unit,
    onOpenScoredRound: () -> Unit,
    onOpenHistory: () -> Unit,
) {
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()

    var result by remember { mutableStateOf<RouletteResult?>(null) }
    var isSpinning by remember { mutableStateOf(false) }
    var isPutting by remember { mutableStateOf(false) }
    val rotation = remember { Animatable(0f) }

    fun spin() {
        if (isSpinning) return
        isSpinning = true
        scope.launch {
            rotation.snapTo(0f)
            rotation.animateTo(
                targetValue = 3f * 360f,
                animationSpec = tween(durationMillis = 2000, easing = LinearOutSlowInEasing),
            )
            val discs = if (isPutting) DiscLists.putting else DiscLists.all
            val spun = if (isPutting) {
                RouletteResult.generatePutt(discs)
            } else {
                RouletteResult.generate(discs)
            }
            result = spun
            isSpinning = false
            container.rouletteHistoryRepository.addResult(spun)
        }
    }

    Scaffold(
        topBar = {
            AppTopBar(title = "Disc Golf Roulette", onBack = onBack) {
                IconButton(onClick = onOpenScoredRound) {
                    Icon(Icons.Default.Scoreboard, contentDescription = "Scored round")
                }
                IconButton(onClick = onOpenHistory) {
                    Icon(Icons.Default.History, contentDescription = "Spin history")
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            SectionCard {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "Spin for your challenge",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Add excitement to your round with random shot challenges.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = AppColors.Muted,
                        textAlign = TextAlign.Center,
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            SectionCard {
                ModeToggleRow(
                    isPutting = isPutting,
                    enabled = !isSpinning,
                    onToggle = {
                        isPutting = it
                        result = null
                    },
                )
            }

            Spacer(Modifier.height(24.dp))

            Box(
                modifier = Modifier
                    .size(250.dp)
                    .semantics {
                        contentDescription = if (isPutting) {
                            "Spin the wheel for a putting challenge"
                        } else {
                            "Spin the wheel for a throwing challenge"
                        }
                    }
                    .clickable(enabled = !isSpinning) { spin() },
                contentAlignment = Alignment.Center,
            ) {
                RouletteWheel(modifier = Modifier.rotate(rotation.value))
            }

            Spacer(Modifier.height(24.dp))

            result?.let { ResultCard(it) }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun ModeToggleRow(isPutting: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = if (isPutting) Icons.Default.GpsFixed else Icons.Default.Album,
            contentDescription = null,
            tint = if (isPutting) AppColors.KnowledgeBase else AppColors.Roulette,
        )
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = if (isPutting) "Putting mode" else "Throwing mode",
                fontWeight = FontWeight.Bold,
                color = if (isPutting) AppColors.KnowledgeBase else AppColors.Roulette,
            )
            Text(
                text = if (isPutting) {
                    "Challenges: putt style, putters only"
                } else {
                    "Challenges: shot type, disc, power, hindrance"
                },
                style = MaterialTheme.typography.bodySmall,
                color = AppColors.Muted,
            )
        }
        Switch(checked = isPutting, onCheckedChange = onToggle, enabled = enabled)
    }
}

@Composable
private fun ResultCard(result: RouletteResult) {
    SectionCard {
        Column(Modifier.fillMaxWidth()) {
            Text(
                "Your challenge",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
            )
            HorizontalDivider(Modifier.padding(vertical = 12.dp))

            if (result.isPutt) {
                LabeledRow(
                    label = "Putt style",
                    value = result.puttStyleDescription,
                    icon = Icons.Default.GpsFixed,
                    iconTint = AppColors.KnowledgeBase,
                )
                Spacer(Modifier.height(12.dp))
                LabeledRow(
                    label = "Disc",
                    value = result.discName ?: "Putter",
                    icon = Icons.Default.Album,
                    iconTint = AppColors.Roulette,
                )
            } else {
                LabeledRow(
                    label = "Shot type",
                    value = result.shotTypeDescription,
                    icon = Icons.Default.Album,
                    iconTint = AppColors.Roulette,
                )
                Spacer(Modifier.height(12.dp))
                LabeledRow(
                    label = "Disc",
                    value = result.discName ?: "Any disc",
                    icon = Icons.Default.Album,
                    iconTint = AppColors.Roulette,
                )
                Spacer(Modifier.height(12.dp))
                LabeledRow(
                    label = "Power",
                    value = result.powerModifier.displayName,
                    icon = Icons.Default.FlashOn,
                    iconTint = AppColors.Roulette,
                )
                Spacer(Modifier.height(12.dp))
                LabeledRow(
                    label = "Challenge",
                    value = result.hindrance.displayName,
                    icon = if (result.hindrance == Hindrance.NONE) {
                        Icons.Default.CheckCircle
                    } else {
                        Icons.Default.Warning
                    },
                    iconTint = if (result.hindrance == Hindrance.NONE) {
                        AppColors.Good
                    } else {
                        AppColors.Warning
                    },
                )
            }

            Spacer(Modifier.height(12.dp))
            Text(
                "Difficulty multiplier ${"%.1f".format(result.difficultyMultiplier)}x",
                style = MaterialTheme.typography.bodySmall,
                color = AppColors.Muted,
            )
        }
    }
}

/** The wheel itself: eight alternating sections with a hub in the middle. */
@Composable
fun RouletteWheel(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(250.dp)
            .shadow(20.dp, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) { drawWheel() }
        Box(
            modifier = Modifier
                .size(80.dp)
                .shadow(10.dp, CircleShape)
                .background(Color.White, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.Casino,
                contentDescription = null,
                tint = Color(0xFF7B1FA2),
                modifier = Modifier.size(40.dp),
            )
        }
    }
}

private fun DrawScope.drawWheel() {
    val sections = 8
    val radius = size.minDimension / 2
    val center = Offset(size.width / 2, size.height / 2)
    val sweep = 360f / sections

    // A radial base so the wheel reads as a disc rather than a flat pie chart.
    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(Color(0xFFBA68C8), Color(0xFF9C27B0), Color(0xFF6A1B9A)),
            center = center,
            radius = radius,
        ),
        radius = radius,
        center = center,
    )

    for (i in 0 until sections) {
        val startAngle = sweep * i
        drawArc(
            color = if (i % 2 == 0) Color(0xFFAB47BC) else Color(0xFF8E24AA),
            startAngle = startAngle,
            sweepAngle = sweep,
            useCenter = true,
            topLeft = Offset(center.x - radius, center.y - radius),
            size = Size(radius * 2, radius * 2),
        )

        val radians = startAngle * PI / 180
        drawLine(
            color = Color.White,
            start = center,
            end = Offset(
                center.x + (radius * cos(radians)).toFloat(),
                center.y + (radius * sin(radians)).toFloat(),
            ),
            strokeWidth = 2f,
        )

        val midRadians = (startAngle + sweep / 2) * PI / 180
        val dotRadius = radius * 0.63f
        drawCircle(
            color = Color.White.copy(alpha = 0.4f),
            radius = 3f,
            center = Offset(
                center.x + (dotRadius * cos(midRadians)).toFloat(),
                center.y + (dotRadius * sin(midRadians)).toFloat(),
            ),
        )
    }

    drawCircle(
        color = Color.White.copy(alpha = 0.25f),
        radius = radius,
        center = center,
        style = Stroke(width = 3f),
    )
}
