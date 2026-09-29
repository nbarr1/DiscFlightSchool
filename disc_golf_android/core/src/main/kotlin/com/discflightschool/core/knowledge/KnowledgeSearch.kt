package com.discflightschool.core.knowledge

import com.discflightschool.core.model.KBArticle
import com.discflightschool.core.model.KBStudy

/**
 * Local keyword search over the bundled research library.
 *
 * Kept free of platform types so the ranking can be exercised without a
 * device.
 */
object KnowledgeSearch {

    private val punctuation = Regex("[^\\w\\s]")
    private val whitespace = Regex("\\s+")

    fun tokenize(text: String): List<String> = text
        .lowercase()
        .replace(punctuation, "")
        .split(whitespace)
        .filter { it.length > 2 }

    fun countMatches(keywords: List<String>, text: String): Int {
        val lower = text.lowercase()
        return keywords.count { lower.contains(it) }
    }

    /**
     * Rank [articles] against [query] and render the top three as a readable
     * answer, with the studies each one cites.
     */
    fun searchLocal(
        query: String,
        articles: List<KBArticle>,
        studies: List<KBStudy>,
    ): String {
        val keywords = tokenize(query)
        if (keywords.isEmpty()) return "Please enter a more specific question."

        val scored = articles.mapNotNull { article ->
            val questionScore = countMatches(keywords, article.question) * 3
            val answerScore = countMatches(keywords, article.answer)
            val findingScore = article.keyFindings.sumOf { countMatches(keywords, it) } * 2
            val total = questionScore + answerScore + findingScore
            if (total > 0) article to total else null
        }.sortedByDescending { it.second }

        if (scored.isEmpty()) {
            return "No matching research found for your question. Try different " +
                "keywords, or browse the categories for tips and FAQs."
        }

        val studiesById = studies.associateBy { it.id }
        val builder = StringBuilder()

        for ((index, entry) in scored.take(3).withIndex()) {
            val article = entry.first
            if (index > 0) builder.append("\n---\n\n")

            builder.append(article.question).append('\n').append('\n')
            builder.append(article.answer).append('\n')

            val sources = article.sourceIds.mapNotNull { studiesById[it] }
            if (sources.isNotEmpty()) {
                builder.append('\n')
                builder.append("Sources: ")
                builder.append(sources.joinToString(", ") { it.citation })
                builder.append('\n')
            }
        }

        return builder.toString().trim()
    }
}
