import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// SSE Client for streaming LLM responses
class SSEClient {
  constructor() {
    this.eventSource = null
    this.sessionId = null
    this.onContentChunk = null
    this.onProcessingComplete = null
    this.onError = null
    this.accumulatedContent = ""
  }

  connect(sessionId, callbacks = {}) {
    // Don't disconnect if we're already connected to the same session
    if (this.sessionId === sessionId && this.isConnected()) {
      console.log(`Already connected to session ${sessionId}`)
      return this.eventSource
    }
    
    this.disconnect() // Clean up any existing connection
    
    this.sessionId = sessionId
    this.onContentChunk = callbacks.onContentChunk || (() => {})
    this.onProcessingComplete = callbacks.onProcessingComplete || (() => {})
    this.onError = callbacks.onError || (() => {})
    this.accumulatedContent = ""

    const url = `/api/stream/${sessionId}`
    console.log(`Connecting to SSE stream: ${url}`)

    this.eventSource = new EventSource(url)

    this.eventSource.addEventListener('connection_established', (event) => {
      console.log('SSE connection established:', event.data)
    })

    this.eventSource.addEventListener('connection_error', (event) => {
      try {
        const data = JSON.parse(event.data)
        console.error('SSE connection error:', data)
        this.onError(data.reason || 'Connection initialization failed')
      } catch (error) {
        console.error('Error parsing connection error:', error)
        this.onError('Connection initialization failed')
      }
    })

    this.eventSource.addEventListener('processing_started', (event) => {
      console.log('Processing started:', event.data)
      this.accumulatedContent = ""
    })

    this.eventSource.addEventListener('content_chunk', (event) => {
      try {
        const data = JSON.parse(event.data)
        this.accumulatedContent += data.content
        
        // Call the callback with both the new chunk and accumulated content
        this.onContentChunk({
          chunk: data.content,
          accumulated: this.accumulatedContent,
          renderedHtml: data.rendered_html
        })
      } catch (error) {
        console.error('Error parsing content chunk:', error)
        this.onError(error)
      }
    })

    this.eventSource.addEventListener('processing_complete', (event) => {
      try {
        const data = JSON.parse(event.data)
        console.log('Processing complete:', data)
        
        this.onProcessingComplete({
          finalContent: data.final_content,
          finalHtml: data.final_html
        })
        
        this.disconnect()
      } catch (error) {
        console.error('Error parsing completion event:', error)
        this.onError(error)
      }
    })

    this.eventSource.addEventListener('error', (event) => {
      try {
        const data = JSON.parse(event.data)
        console.error('SSE error:', data)
        this.onError(data.reason || 'Unknown error')
      } catch (error) {
        console.error('SSE connection error:', error)
        this.onError('Connection error')
      }
    })

    this.eventSource.addEventListener('timeout', (event) => {
      console.log('SSE timeout:', event.data)
      this.onError('Connection timeout')
      this.disconnect()
    })

    this.eventSource.addEventListener('heartbeat', (event) => {
      // Just log heartbeat, no action needed
      console.debug('SSE heartbeat received')
    })

    this.eventSource.onerror = (error) => {
      console.error('EventSource failed:', error)
      
      // Check if the connection is still open
      if (this.eventSource.readyState === EventSource.CLOSED) {
        console.log('SSE connection was closed')
        // Only call onError if we weren't expecting the closure
        if (this.sessionId) {
          this.onError('Connection closed unexpectedly')
        }
      } else if (this.eventSource.readyState === EventSource.CONNECTING) {
        console.log('SSE connection is reconnecting...')
        // Don't call onError immediately, let it try to reconnect
        // Set a timeout to call onError if reconnection takes too long
        setTimeout(() => {
          if (this.eventSource && this.eventSource.readyState === EventSource.CONNECTING) {
            this.onError('Connection timeout during reconnection')
          }
        }, 10000) // 10 second timeout for reconnection
      } else {
        this.onError('Connection failed')
      }
    }

    return this.eventSource
  }

  disconnect() {
    if (this.eventSource) {
      console.log('Disconnecting SSE stream')
      this.eventSource.close()
      this.eventSource = null
    }
    this.sessionId = null
    this.accumulatedContent = ""
  }

  isConnected() {
    return this.eventSource && this.eventSource.readyState === EventSource.OPEN
  }
}

// Create global SSE client instance
window.sseClient = new SSEClient()

// LiveView hooks for streaming functionality
let Hooks = {}

Hooks.StreamingToggle = {
  mounted() {
    this.el.addEventListener('change', (event) => {
      const isStreaming = event.target.checked
      this.pushEvent('toggle_streaming', { streaming: isStreaming })
    })
  }
}

Hooks.StreamingController = {
  mounted() {
    // Listen for SSE establishment events
    this.handleEvent("establish_sse", ({ session_id }) => {
      console.log(`Establishing SSE connection for session: ${session_id}`)
      
      // Pre-establish SSE connection
      window.sseClient.connect(session_id, {
        onContentChunk: (data) => {
          // Find streaming result element and update it
          const streamingElement = document.querySelector(`[data-session-id="${session_id}"] .streaming-justification`)
          if (streamingElement) {
            streamingElement.innerHTML = data.renderedHtml || this.escapeHtml(data.accumulated)
            streamingElement.scrollTop = streamingElement.scrollHeight
          }
        },

        onProcessingComplete: (data) => {
          // Notify LiveView that streaming is complete
          this.pushEvent('streaming_complete', {
            session_id: session_id,
            final_content: data.finalContent,
            final_html: data.finalHtml
          })
        },

        onError: (error) => {
          console.error('SSE Error:', error)
          this.pushEvent('streaming_error', {
            session_id: session_id,
            error: error
          })
        }
      })
    })
  },

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}

Hooks.StreamingResult = {
  mounted() {
    this.sessionId = this.el.dataset.sessionId
    this.streamingEnabled = this.el.dataset.streaming === 'true'
    
    if (this.streamingEnabled && this.sessionId) {
      this.startStreaming()
    }
  },

  updated() {
    const newSessionId = this.el.dataset.sessionId
    const newStreamingEnabled = this.el.dataset.streaming === 'true'
    
    if (newStreamingEnabled && newSessionId && newSessionId !== this.sessionId) {
      this.sessionId = newSessionId
      this.startStreaming()
    } else if (!newStreamingEnabled) {
      window.sseClient.disconnect()
    }
  },

  destroyed() {
    window.sseClient.disconnect()
  },

  startStreaming() {
    const justificationElement = this.el.querySelector('.streaming-justification')
    const progressElement = this.el.querySelector('.streaming-progress')
    
    if (!justificationElement) {
      console.error('Streaming justification element not found')
      return
    }

    // Show progress indicator
    if (progressElement) {
      progressElement.classList.remove('hidden')
    }

    window.sseClient.connect(this.sessionId, {
      onContentChunk: (data) => {
        // Update the justification content progressively
        justificationElement.innerHTML = data.renderedHtml || this.escapeHtml(data.accumulated)
        
        // Scroll to bottom of content
        justificationElement.scrollTop = justificationElement.scrollHeight
      },

      onProcessingComplete: (data) => {
        // Final update with complete content
        justificationElement.innerHTML = data.finalHtml || this.escapeHtml(data.finalContent)
        
        // Hide progress indicator
        if (progressElement) {
          progressElement.classList.add('hidden')
        }

        // Notify LiveView that streaming is complete
        this.pushEvent('streaming_complete', {
          session_id: this.sessionId,
          final_content: data.finalContent,
          final_html: data.finalHtml
        })
      },

      onError: (error) => {
        console.error('Streaming error:', error)
        
        // Hide progress indicator
        if (progressElement) {
          progressElement.classList.add('hidden')
        }

        // Show error message
        justificationElement.innerHTML = `<div class="alert alert-error"><span>Streaming error: ${error}</span></div>`
        
        // Notify LiveView of the error
        this.pushEvent('streaming_error', {
          session_id: this.sessionId,
          error: error
        })
      }
    })
  },

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}

// Hook for handling file downloads
window.addEventListener("phx:download", (event) => {
  const { filename, data, mime_type } = event.detail
  
  // Create blob and download link
  const blob = new Blob([data], { type: mime_type })
  const url = window.URL.createObjectURL(blob)
  
  // Create temporary download link
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.style.display = 'none'
  
  // Trigger download
  document.body.appendChild(link)
  link.click()
  
  // Cleanup
  document.body.removeChild(link)
  window.URL.revokeObjectURL(url)
})

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Clean up SSE connections when navigating away
window.addEventListener("beforeunload", () => {
  window.sseClient.disconnect()
})

// Clean up SSE connections on page visibility change (mobile/tab switching)
// Only disconnect if page is hidden for more than 5 seconds to avoid premature disconnection
let visibilityTimeout = null
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    // Set a timeout before disconnecting to avoid race conditions
    visibilityTimeout = setTimeout(() => {
      window.sseClient.disconnect()
    }, 5000) // 5 second delay
  } else {
    // Page is visible again, cancel the disconnect timeout
    if (visibilityTimeout) {
      clearTimeout(visibilityTimeout)
      visibilityTimeout = null
    }
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket