package com.discflightschool.core

import com.discflightschool.core.knowledge.KnowledgeSearch
import com.discflightschool.core.model.KBArticle
import com.discflightschool.core.model.KBStudy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KnowledgeSearchTest {

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
