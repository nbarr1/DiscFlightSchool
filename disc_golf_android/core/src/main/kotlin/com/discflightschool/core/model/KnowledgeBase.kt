package com.discflightschool.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class KBStudy(
    val id: String,
    val title: String,
    val authors: String,
    val year: Int,
    val filename: String,
    val summary: String,
) {
    val citation: String get() = "$authors ($year)"
}

@Serializable
data class KBArticle(
    val id: String,
    val category: String,
    /** Either `faq` or `tip`. */
    val type: String,
    val question: String,
    val answer: String,
    @SerialName("keyFindings") val keyFindings: List<String> = emptyList(),
    @SerialName("sourceIds") val sourceIds: List<String> = emptyList(),
) {
    val isFaq: Boolean get() = type == "faq"
    val isTip: Boolean get() = type == "tip"
}

@Serializable
data class KBCategory(
    val id: String,
    val name: String,
    val iconName: String,
    val colorValue: Long,
    val description: String,
)

@Serializable
data class KnowledgeBaseContent(
    val studies: List<KBStudy> = emptyList(),
    val categories: List<KBCategory> = emptyList(),
    val articles: List<KBArticle> = emptyList(),
)
