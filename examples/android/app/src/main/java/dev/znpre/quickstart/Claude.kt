package dev.znpre.quickstart

import com.anthropic.client.okhttp.AnthropicOkHttpClient
import com.anthropic.core.JsonValue
import com.anthropic.models.messages.MessageCreateParams
import com.anthropic.models.messages.OutputConfig

/**
 * Streams answers from Claude with the official Anthropic Java SDK
 * (`com.anthropic:anthropic-java`). Call `reply` off the main thread.
 */
class Claude(apiKey: String) {
    data class Turn(val fromUser: Boolean, val text: String)

    /** Any Claude model works here. "claude-haiku-5-5" is the fastest and cheapest. */
    var model = "claude-opus-5-5"

    private val client = AnthropicOkHttpClient.builder().apiKey(apiKey).build()

    /** Streams the answer to `history`; `onText` gets each piece. Returns the whole answer. */
    fun reply(system: String, history: List<Turn>, onText: (String) -> Unit): String {
        val params = MessageCreateParams.builder()
            .model(model)
            .maxTokens(4096L)
            .system(system)
            // Low effort: quick, short spoken answers.
            .outputConfig(OutputConfig.builder().effort(OutputConfig.Effort.LOW).build())
            // If a safety check declines a request, the API retries it on a fallback model.
            .putAdditionalHeader("anthropic-beta", "server-side-fallback-2026-07-01")
            .putAdditionalBodyProperty("fallbacks", JsonValue.from("default"))
            .apply {
                history.forEach { if (it.fromUser) addUserMessage(it.text) else addAssistantMessage(it.text) }
            }
            .build()

        val answer = StringBuilder()
        client.messages().createStreaming(params).use { stream ->
            stream.stream()
                .flatMap { event -> event.contentBlockDelta().stream() }
                .flatMap { delta -> delta.delta().text().stream() }
                .forEach { piece ->
                    answer.append(piece.text())
                    onText(piece.text())
                }
        }
        return answer.toString()
    }
}
