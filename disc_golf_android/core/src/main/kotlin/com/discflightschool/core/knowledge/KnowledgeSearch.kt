package com.discflightschool.core.knowledge

import com.discflightschool.core.model.KBArticle
import com.discflightschool.core.model.KBStudy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Local keyword search over the bundled research library, and the parsing an
 * AI-assisted answer needs on the way back.
 *
 * Kept free of platform types so the ranking and the response handling can be
 * exercised without a network or a device.
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

/**
 * The Anthropic Messages API details the AI search depends on, separated from
 * the HTTP call itself so both can be checked without a network.
 */
object ClaudeMessages {

    /**
     * The model used for AI search. Kept as a named constant so the migration
     * point is obvious the next time the model line moves.
     */
    const val MODEL = "claude-sonnet-5"

    /**
     * The output cap for an answer. The system prompt asks for under 200 words
     * (roughly 300 tokens); the headroom absorbs citation-heavy replies without
     * truncating mid-sentence.
     */
    const val MAX_TOKENS = 1024

    const val TIMEOUT_SECONDS = 45L

    const val ENDPOINT = "https://api.anthropic.com/v1/messages"

    const val API_VERSION = "2023-06-01"

    /** The grounded-research system prompt, built from the bundled study list. */
    fun systemPrompt(studies: List<KBStudy>): String {
        val studySummaries = studies.joinToString("\n") {
            "- ${it.citation}: \"${it.title}\" — ${it.summary}"
        }
        return """
            You are a disc golf research assistant embedded in the Disc Flight School app. Answer questions using ONLY the peer-reviewed research summaries provided below. Be concise, practical, and cite sources by author name and year. If the research doesn't cover the question, say so honestly.

            Research library:
            $studySummaries

            Guidelines:
            - Cite sources inline, e.g. (Greenway, 2007)
            - Give actionable advice when possible
            - Use specific numbers from the research
            - Keep answers under 200 words
        """.trimIndent()
    }

    /**
     * Pull the answer text out of a `/v1/messages` response body.
     *
     * `content` is a heterogeneous block list — with adaptive thinking enabled
     * the first block can be a `thinking` block that carries no `text` field, so
     * blocks must be selected by `type` rather than by position. Multiple text
     * blocks are concatenated, since citations can split them.
     *
     * Returns null when the response carries no text block at all.
     */
    fun extractAnswerText(body: JsonObject): String? {
        val content = body["content"] ?: return null
        val blocks = runCatching { content.jsonArray }.getOrNull() ?: return null

        val builder = StringBuilder()
        for (block in blocks) {
            val obj = block as? JsonObject ?: continue
            if ((obj["type"] as? JsonPrimitive)?.content != "text") continue
            val text = obj["text"] as? JsonPrimitive ?: continue
            if (text.isString) builder.append(text.content)
        }

        return builder.toString().trim().ifEmpty { null }
    }

    /** The `stop_reason` of a response, or null when absent. */
    fun stopReason(body: JsonObject): String? =
        (body["stop_reason"] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Map a non-200 response to a user-facing message. */
    fun messageForErrorStatus(statusCode: Int): String = when (statusCode) {
        401 -> "Invalid API key. Please check your key in Settings."
        403 -> "This API key is not permitted to use AI search. Check the key's " +
            "permissions in the Anthropic Console."
        429 -> "Rate limited by the Anthropic API. Please wait a moment and try again."
        529 -> "The Anthropic API is temporarily overloaded. Please try again in a moment."
        else -> if (statusCode >= 500) {
            "Anthropic API server error ($statusCode). Please try again later."
        } else {
            "API error ($statusCode). Please try again later."
        }
    }

    /**
     * Turn a raw response into the text the user sees.
     *
     * Every failure mode ends as a sentence rather than an exception: a
     * non-200, a body that is not JSON, a body that is JSON but not an object,
     * a refusal, and an answer cut short by the token cap each have their own
     * message, so the screen never has to guess what went wrong.
     */
    fun answerFromResponse(statusCode: Int, body: String?): String {
        if (statusCode != 200) return messageForErrorStatus(statusCode)

        val parsed = runCatching {
            Json.parseToJsonElement(body.orEmpty())
        }.getOrNull()

        val obj = when (parsed) {
            is JsonObject -> parsed
            // A JSON array is a real response in the wrong shape.
            is JsonArray -> return "Unexpected response from the Anthropic API. Please try again."
            // Anything else — an unparseable body, or a bare scalar — is a
            // captive portal or proxy page rather than the API answering.
            else -> return CONNECTION_ERROR
        }

        if (stopReason(obj) == "refusal") {
            return "Claude declined to answer that question. Try rephrasing it " +
                "around the disc golf research in the library."
        }

        val answer = extractAnswerText(obj) ?: return "No response received."

        if (stopReason(obj) == "max_tokens") {
            return "$answer\n\n_(Answer was cut off at the length limit — try " +
                "asking a narrower question.)_"
        }

        return answer
    }

    /** The message shown when the request never reached the API. */
    const val CONNECTION_ERROR =
        "Connection error. Please check your internet connection and try again."

    /** The message shown when the request ran past [TIMEOUT_SECONDS]. */
    const val TIMEOUT_ERROR =
        "The request to Anthropic timed out. Please check your connection and try again."

    /** The message shown when no API key has been configured. */
    const val NO_API_KEY =
        "Please add your Anthropic API key in Settings to use AI search."

    /** The request body for one grounded question. */
    fun requestBody(question: String, systemPrompt: String): String {
        val json = kotlinx.serialization.json.Json
        return json.encodeToString(
            kotlinx.serialization.json.JsonObject.serializer(),
            kotlinx.serialization.json.buildJsonObject {
                put("model", JsonPrimitive(MODEL))
                put("max_tokens", JsonPrimitive(MAX_TOKENS))
                // Grounded Q&A over a small supplied corpus with a sub-200-word
                // answer: thinking buys little here and costs the user latency
                // and tokens on their own key. Disabled explicitly because
                // omitting `thinking` runs adaptive by default.
                put(
                    "thinking",
                    kotlinx.serialization.json.buildJsonObject {
                        put("type", JsonPrimitive("disabled"))
                    },
                )
                put("system", JsonPrimitive(systemPrompt))
                put(
                    "messages",
                    kotlinx.serialization.json.JsonArray(
                        listOf(
                            kotlinx.serialization.json.buildJsonObject {
                                put("role", JsonPrimitive("user"))
                                put("content", JsonPrimitive(question))
                            },
                        ),
                    ),
                )
            },
        )
    }
}
