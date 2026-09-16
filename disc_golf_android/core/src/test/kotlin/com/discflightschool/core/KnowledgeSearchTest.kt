package com.discflightschool.core

import com.discflightschool.core.knowledge.ClaudeMessages
import com.discflightschool.core.knowledge.KnowledgeSearch
import com.discflightschool.core.model.KBArticle
import com.discflightschool.core.model.KBStudy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KnowledgeSearchTest {

    private fun body(raw: String) = Json.parseToJsonElement(raw).jsonObject

    private val studies = listOf(
        KBStudy(
            id = "greenway_2007",
            title = "Disc golf throwing mechanics",
            authors = "Greenway",
            year = 2007,
            filename = "greenway.pdf",
            summary = "Grip pressure and release angle drive distance.",
        ),
    )

    private val articles = listOf(
        KBArticle(
            id = "bio_faq_1",
            category = "biomechanics",
            type = "faq",
            question = "How do I throw a disc further?",
            answer = "Generate speed from the legs and keep the disc close through the pull.",
            keyFindings = listOf("Hip rotation precedes shoulder rotation"),
            sourceIds = listOf("greenway_2007"),
        ),
        KBArticle(
            id = "putt_tip_1",
            category = "putting",
            type = "tip",
            question = "What putting stance should I use?",
            answer = "Straddle putting helps around obstacles.",
        ),
    )

    // ── extractAnswerText ────────────────────────────────────────────────

    @Test
    fun `reads a plain text block`() {
        assertEquals(
            "hello",
            ClaudeMessages.extractAnswerText(
                body("""{"content": [{"type": "text", "text": "hello"}]}"""),
            ),
        )
    }

    @Test
    fun `skips a leading thinking block`() {
        // Reading content[0].text unconditionally breaks here: with adaptive
        // thinking on, the first block can be a thinking block with no `text`.
        val answer = ClaudeMessages.extractAnswerText(
            body(
                """
                {"content": [
                  {"type": "thinking", "thinking": "", "signature": "abc"},
                  {"type": "text", "text": "the real answer"}
                ]}
                """.trimIndent(),
            ),
        )
        assertEquals("the real answer", answer)
    }

    @Test
    fun `concatenates multiple text blocks`() {
        val answer = ClaudeMessages.extractAnswerText(
            body(
                """
                {"content": [
                  {"type": "text", "text": "part one. "},
                  {"type": "text", "text": "part two."}
                ]}
                """.trimIndent(),
            ),
        )
        assertEquals("part one. part two.", answer)
    }

    @Test
    fun `ignores non-text blocks entirely`() {
        assertNull(
            ClaudeMessages.extractAnswerText(
                body(
                    """
                    {"content": [
                      {"type": "tool_use", "id": "t1", "name": "x", "input": {}},
                      {"type": "redacted_thinking", "data": "zzz"}
                    ]}
                    """.trimIndent(),
                ),
            ),
        )
    }

    @Test
    fun `returns null for an empty content list`() {
        assertNull(ClaudeMessages.extractAnswerText(body("""{"content": []}""")))
    }

    @Test
    fun `returns null when content is missing or malformed`() {
        assertNull(ClaudeMessages.extractAnswerText(body("{}")))
        assertNull(ClaudeMessages.extractAnswerText(body("""{"content": "not a list"}""")))
    }

    @Test
    fun `returns null when text blocks are blank`() {
        assertNull(
            ClaudeMessages.extractAnswerText(
                body("""{"content": [{"type": "text", "text": "   "}]}"""),
            ),
        )
    }

    @Test
    fun `tolerates a text block with a non-string text field`() {
        assertEquals(
            "ok",
            ClaudeMessages.extractAnswerText(
                body(
                    """
                    {"content": [
                      {"type": "text", "text": 42},
                      {"type": "text", "text": "ok"}
                    ]}
                    """.trimIndent(),
                ),
            ),
        )
    }

    // ── messageForErrorStatus ────────────────────────────────────────────

    @Test
    fun `401 tells the user to check their key`() {
        assertTrue(ClaudeMessages.messageForErrorStatus(401).contains("Invalid API key"))
    }

    @Test
    fun `429 mentions rate limiting`() {
        assertTrue(ClaudeMessages.messageForErrorStatus(429).contains("Rate limited"))
    }

    @Test
    fun `529 mentions overload`() {
        assertTrue(ClaudeMessages.messageForErrorStatus(529).contains("overloaded"))
    }

    @Test
    fun `5xx is reported as a server error`() {
        assertTrue(ClaudeMessages.messageForErrorStatus(500).contains("server error"))
    }

    @Test
    fun `unknown statuses still produce a message with the code`() {
        assertTrue(ClaudeMessages.messageForErrorStatus(418).contains("418"))
    }

    // ── request shape ────────────────────────────────────────────────────

    @Test
    fun `targets a current, non-retired model`() {
        // Pinning a dated snapshot is what broke AI search the last time.
        assertFalse(ClaudeMessages.MODEL.contains("20250514"))
        assertEquals("claude-sonnet-5", ClaudeMessages.MODEL)
    }

    @Test
    fun `sends the documented body`() {
        val request = Json.parseToJsonElement(
            ClaudeMessages.requestBody(
                question = "How do I throw further?",
                systemPrompt = ClaudeMessages.systemPrompt(studies),
            ),
        ).jsonObject

        assertEquals(ClaudeMessages.MODEL, request.getValue("model").jsonPrimitive.content)
        assertEquals(
            ClaudeMessages.MAX_TOKENS,
            request.getValue("max_tokens").jsonPrimitive.content.toInt(),
        )
        assertTrue(
            request.getValue("system").jsonPrimitive.content
                .contains("disc golf research assistant"),
        )
        val message = request.getValue("messages").jsonArray.single().jsonObject
        assertEquals("How do I throw further?", message.getValue("content").jsonPrimitive.content)
        assertEquals("user", message.getValue("role").jsonPrimitive.content)
    }

    @Test
    fun `disables thinking explicitly so max_tokens covers only the answer`() {
        // Omitting `thinking` runs adaptive thinking, and max_tokens caps
        // thinking and text together — a short cap would truncate the answer.
        val request = Json.parseToJsonElement(
            ClaudeMessages.requestBody("q", "system"),
        ).jsonObject

        assertEquals(
            "disabled",
            request.getValue("thinking").jsonObject.getValue("type").jsonPrimitive.content,
        )
    }

    @Test
    fun `does not send removed sampling parameters`() {
        // temperature, top_p, and top_k are rejected on current models.
        val request = Json.parseToJsonElement(
            ClaudeMessages.requestBody("q", "system"),
        ).jsonObject

        assertFalse(request.containsKey("temperature"))
        assertFalse(request.containsKey("top_p"))
        assertFalse(request.containsKey("top_k"))
    }

    @Test
    fun `the system prompt carries the research library`() {
        val prompt = ClaudeMessages.systemPrompt(studies)
        assertTrue(prompt.contains("Greenway (2007)"))
        assertTrue(prompt.contains("Grip pressure"))
    }

    // ── response handling ────────────────────────────────────────────────

    private fun messageBody(
        content: String = """[{"type": "text", "text": "Grip pressure matters (Greenway, 2007)."}]""",
        stopReason: String = "end_turn",
    ) = """{"content": $content, "stop_reason": "$stopReason"}"""

    @Test
    fun `returns the answer text`() {
        assertEquals(
            "Grip pressure matters (Greenway, 2007).",
            ClaudeMessages.answerFromResponse(200, messageBody()),
        )
    }

    @Test
    fun `survives a thinking block arriving first`() {
        val answer = ClaudeMessages.answerFromResponse(
            200,
            messageBody(
                content = """
                    [{"type": "thinking", "thinking": "", "signature": "sig"},
                     {"type": "text", "text": "answer after thinking"}]
                """.trimIndent(),
            ),
        )
        assertEquals("answer after thinking", answer)
    }

    @Test
    fun `flags a truncated answer instead of presenting it as complete`() {
        val answer = ClaudeMessages.answerFromResponse(
            200,
            messageBody(stopReason = "max_tokens"),
        )
        assertTrue(answer.contains("Grip pressure matters"))
        assertTrue(answer.contains("cut off"))
    }

    @Test
    fun `reports a refusal distinctly`() {
        val answer = ClaudeMessages.answerFromResponse(
            200,
            messageBody(content = "[]", stopReason = "refusal"),
        )
        assertTrue(answer.contains("declined"))
    }

    @Test
    fun `maps a 401 to the invalid-key message`() {
        assertTrue(
            ClaudeMessages.answerFromResponse(401, """{"error":{}}""").contains("Invalid API key"),
        )
    }

    @Test
    fun `handles a non-JSON body without throwing`() {
        assertTrue(
            ClaudeMessages.answerFromResponse(200, "<html>gateway</html>")
                .contains("Connection error"),
        )
    }

    @Test
    fun `handles a JSON body that is not an object`() {
        assertTrue(
            ClaudeMessages.answerFromResponse(200, "[1,2,3]").contains("Unexpected response"),
        )
    }

    @Test
    fun `a request timeout is configured and is not minutes long`() {
        assertTrue(ClaudeMessages.TIMEOUT_SECONDS > 0)
        // A mobile client should not hang for minutes on a dead server.
        assertTrue(ClaudeMessages.TIMEOUT_SECONDS <= 120)
    }

    // ── local keyword search ─────────────────────────────────────────────

    @Test
    fun `asks for a more specific question when the query has no keywords`() {
        assertTrue(
            KnowledgeSearch.searchLocal("a an of", articles, studies).contains("more specific"),
        )
        assertTrue(KnowledgeSearch.searchLocal("", articles, studies).contains("more specific"))
    }

    @Test
    fun `reports no matches against an empty library`() {
        assertTrue(
            KnowledgeSearch.searchLocal("hyzer flip distance", emptyList(), emptyList())
                .contains("No matching"),
        )
    }

    @Test
    fun `ranks a question match above an answer-only match and cites its sources`() {
        val answer = KnowledgeSearch.searchLocal("throw further", articles, studies)

        assertTrue(answer.startsWith("How do I throw a disc further?"))
        assertTrue(answer.contains("Sources: Greenway (2007)"))
        assertFalse(answer.contains("Straddle putting"))
    }

    @Test
    fun `tokenizing drops punctuation and very short words`() {
        assertEquals(
            listOf("how", "far", "can", "disc", "fly"),
            KnowledgeSearch.tokenize("How far can a disc fly?!"),
        )
    }
}
