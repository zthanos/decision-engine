# Implementation Plan

- [x] 1. Create core domain type definitions and infrastructure





  - Create DecisionEngine.Types module with domain type definitions and configuration structures
  - Set up directory structure for domain-specific configurations in priv/rules/
  - Create sample configuration files for power_platform, data_platform, and integration_platform domains
  - _Requirements: 1.1, 2.1_

- [x] 1.1 Write property test for domain type support






  - **Property 1: Domain Support Completeness**
  - **Validates: Requirements 1.1**

- [x] 2. Implement domain configuration loading system





  - Create DecisionEngine.RuleConfig module with domain-specific JSON loading
  - Implement configuration validation and error handling
  - Add caching mechanism for loaded configurations
  - _Requirements: 2.1, 2.2, 8.1, 8.2_

- [ ]* 2.1 Write property test for configuration loading
  - **Property 2: Domain Configuration Loading**
  - **Validates: Requirements 1.3, 2.1, 2.2**

- [ ]* 2.2 Write property test for configuration structure validation
  - **Property 5: Configuration Structure Validation**
  - **Validates: Requirements 2.3**

- [ ]* 2.3 Write property test for configuration file naming
  - **Property 17: Configuration File Naming Convention**
  - **Validates: Requirements 8.1**

- [x] 3. Create domain-specific signal schema system











  - Refactor existing DecisionEngine.SignalsSchema to be domain coordinator
  - Create DecisionEngine.SignalsSchema.PowerPlatform module (migrate existing schema)
  - Create DecisionEngine.SignalsSchema.DataPlatform module with data platform specific fields
  - Create DecisionEngine.SignalsSchema.IntegrationPlatform module with integration specific fields
  - Implement schema module mapping and loading logic
  - _Requirements: 3.1, 3.2, 3.3_

- [ ]* 3.1 Write property test for schema module mapping
  - **Property 7: Schema Module Mapping**
  - **Validates: Requirements 3.1**

- [ ]* 3.2 Write property test for domain schema isolation
  - **Property 9: Domain Schema Isolation**
  - **Validates: Requirements 3.5**

- [x] 4. Enhance RuleEngine for domain-agnostic processing






  - Modify RuleEngine.evaluate/2 to accept rule_config parameter instead of hard-coded patterns
  - Implement generic condition evaluation supporting in, intersects, not_intersects operators
  - Update pattern matching logic to work with configuration-driven patterns
  - Ensure domain-agnostic processing of any valid rule configuration
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 2.4_

- [ ]* 4.1 Write property test for rule engine domain agnosticism
  - **Property 16: Rule Engine Domain Agnosticism**
  - **Validates: Requirements 7.1, 7.2, 7.3, 7.4**

- [ ]* 4.2 Write property test for operator support consistency
  - **Property 6: Operator Support Consistency**
  - **Validates: Requirements 2.4**

- [x] 5. Update LLMClient for domain-aware processing






  - Modify extract_signals/6 to accept domain, schema_module, and rule_config parameters
  - Implement build_extraction_prompt/5 with domain-specific context and pattern summaries
  - Update prompt generation to include domain-specific field descriptions
  - Enhance retry logic with domain-specific guidance
  - Update generate_justification/4 to include domain context
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

- [ ]* 5.1 Write property test for LLM client domain context
  - **Property 10: LLM Client Domain Context**
  - **Validates: Requirements 4.1**

- [ ]* 5.2 Write property test for domain-aware prompt generation
  - **Property 11: Domain-Aware Prompt Generation**
  - **Validates: Requirements 4.2, 4.3**

- [x] 5.3. Implement markdown rendering system





  - Create DecisionEngine.MarkdownRenderer module for safe HTML conversion
  - Add Earmark and HtmlSanitizeEx dependencies for markdown processing and XSS protection
  - Implement render_to_html/1 and render_to_html!/1 functions with error handling
  - Add HTML sanitization to prevent XSS attacks while preserving formatting
  - Implement graceful fallback to escaped raw text for malformed markdown
  - _Requirements: 9.2, 9.4, 9.5_

- [ ]* 5.4 Write property test for markdown content generation
  - **Property 20: Markdown Content Generation**
  - **Validates: Requirements 9.1**

- [ ]* 5.5 Write property test for markdown to HTML rendering
  - **Property 21: Markdown to HTML Rendering**
  - **Validates: Requirements 9.2, 9.4**

- [ ]* 5.6 Write property test for markdown formatting preservation
  - **Property 22: Markdown Formatting Preservation**
  - **Validates: Requirements 9.3**

- [ ]* 5.7 Write property test for markdown parsing fallback
  - **Property 23: Markdown Parsing Fallback**
  - **Validates: Requirements 9.5**

- [x] 6. Enhance main DecisionEngine API for multi-domain support





  - Update DecisionEngine.process/3 to accept domain parameter
  - Implement automatic loading of domain-specific configurations and schemas
  - Add domain information to result structure
  - Integrate MarkdownRenderer to convert LLM justifications to HTML
  - Update result structure to include both raw markdown and rendered HTML
  - Maintain backward compatibility with process/2 using default domain
  - Implement comprehensive error handling with domain context
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 9.1, 9.2_

- [ ]* 6.1 Write property test for API domain parameter handling
  - **Property 12: API Domain Parameter Handling**
  - **Validates: Requirements 5.1, 5.2**

- [ ]* 6.2 Write property test for domain information in results
  - **Property 13: Domain Information in Results**
  - **Validates: Requirements 5.3**

- [ ]* 6.3 Write property test for backward compatibility
  - **Property 14: Backward Compatibility Preservation**
  - **Validates: Requirements 5.5**

- [x] 7. Checkpoint - Ensure all core domain functionality tests pass






  - Ensure all tests pass, ask the user if questions arise.


- [x] 8. Update LiveView interface for domain selection





  - Add domain selection dropdown to DecisionLive.Index
  - Implement domain state management in LiveView assigns
  - Add handle_event for domain selection changes
  - Update process_scenario/2 to use selected domain
  - Update result display to render markdown justifications as HTML
  - Add CSS styling for rendered markdown content (headers, lists, emphasis)
  - Ensure domain information is displayed in results
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 9.2, 9.3_

- [ ]* 8.1 Write property test for UI domain state consistency
  - **Property 15: UI Domain State Consistency**
  - **Validates: Requirements 6.2, 6.3**

- [x] 9. Implement domain extensibility features












  - Add support for dynamic domain discovery from configuration files
  - Implement configuration reloading without application restart
  - Add validation for new domain configurations
  - Create helper functions for adding new domains
  - _Requirements: 1.5, 3.4, 8.4_

- [ ]* 9.1 Write property test for domain extensibility
  - **Property 4: Domain Extensibility**
  - **Validates: Requirements 1.5, 3.4**

- [ ]* 9.2 Write property test for configuration reloading
  - **Property 19: Configuration Reloading**
  - **Validates: Requirements 8.4**

- [ ] 10. Implement comprehensive error handling and recovery
  - Add domain-specific error contexts throughout the system
  - Implement graceful fallback mechanisms for missing configurations
  - Create consistent error message formatting with domain information
  - Add error recovery suggestions for common issues
  - _Requirements: 2.5, 8.2, 8.3_

- [ ]* 10.1 Write property test for configuration parsing robustness
  - **Property 18: Configuration Parsing Robustness**
  - **Validates: Requirements 2.5, 8.2**

- [ ] 11. Add domain processing isolation and validation
  - Implement tests to verify domain-specific processing produces appropriate results
  - Add validation that domain changes don't affect other domains
  - Create domain-specific signal extraction validation
  - Ensure domain isolation in concurrent processing scenarios
  - _Requirements: 1.4, 3.2, 3.3, 3.5_

- [ ]* 11.1 Write property test for domain processing isolation
  - **Property 3: Domain Processing Isolation**
  - **Validates: Requirements 1.4**

- [ ]* 11.2 Write property test for domain-specific signal extraction
  - **Property 8: Domain-Specific Signal Extraction**
  - **Validates: Requirements 3.2, 3.3**

- [ ] 12. Final integration and testing
  - Create end-to-end integration tests for all domains
  - Test domain switching workflows in LiveView
  - Validate configuration reloading functionality
  - Test error scenarios and recovery mechanisms
  - Performance test with multiple domains and concurrent requests
  - _Requirements: All requirements integration testing_

- [x] 13. Implement Server-Sent Events (SSE) streaming infrastructure





  - Create DecisionEngine.StreamManager GenServer for managing SSE streams
  - Implement stream lifecycle management (start, chunk handling, completion, cleanup)
  - Add Registry for tracking active stream sessions
  - Create SSE event formatting and delivery functions
  - Add proper error handling and timeout management
  - _Requirements: 10.1, 10.4, 10.6, 10.7_

- [ ]* 13.1 Write property test for SSE connection establishment
  - **Property 24: SSE Connection Establishment**
  - **Validates: Requirements 10.1**

- [ ]* 13.2 Write property test for stream completion handling
  - **Property 27: Stream Completion Handling**
  - **Validates: Requirements 10.4**

- [ ]* 13.3 Write property test for concurrent stream isolation
  - **Property 29: Concurrent Stream Isolation**
  - **Validates: Requirements 10.6**

- [ ]* 13.4 Write property test for stream cleanup on cancellation
  - **Property 30: Stream Cleanup on Cancellation**
  - **Validates: Requirements 10.7**

- [x] 14. Enhance LLMClient for streaming support






  - Add stream_justification/5 function for streaming LLM responses
  - Implement call_llm_stream/3 for streaming LLM API calls
  - Add streaming configuration support in LLM client
  - Implement chunk-based content delivery to StreamManager
  - Add proper error handling for streaming failures
  - _Requirements: 10.2_

- [ ]* 14.1 Write property test for LLM content streaming
  - **Property 25: LLM Content Streaming**
  - **Validates: Requirements 10.2**

- [x] 15. Create SSE Phoenix controller






  - Implement DecisionEngineWeb.SSEController for handling SSE connections
  - Add stream/2 action with proper SSE headers and chunked response
  - Implement SSE event loop with timeout handling
  - Add proper connection cleanup and error handling
  - Create SSE event formatting functions
  - Update router to include SSE endpoint
  - _Requirements: 10.1, 10.4, 10.7_

- [x] 16. Enhance DecisionEngine API for streaming





  - Add process_streaming/4 function to main DecisionEngine API
  - Integrate StreamManager with processing workflow
  - Implement streaming result structure with session tracking
  - Add fallback mechanism from streaming to traditional processing
  - Ensure backward compatibility with existing process/2 and process/3 functions
  - _Requirements: 10.5_

- [ ]* 16.1 Write property test for SSE fallback mechanism
  - **Property 28: SSE Fallback Mechanism**
  - **Validates: Requirements 10.5**

- [x] 17. Update LiveView interface for streaming support





  - Add JavaScript client for handling SSE connections
  - Implement progressive content rendering in the UI
  - Add streaming mode toggle and session management
  - Update process_scenario/2 to support streaming mode
  - Implement real-time markdown rendering of streamed content
  - Add proper cleanup when user navigates away
  - _Requirements: 10.3, 10.7_

- [ ]* 17.1 Write property test for progressive markdown rendering
  - **Property 26: Progressive Markdown Rendering**
  - **Validates: Requirements 10.3**

- [ ] 18. Checkpoint - Ensure all streaming functionality tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 19. Final integration and testing
  - Create end-to-end integration tests for all domains
  - Test domain switching workflows in LiveView
  - Validate configuration reloading functionality
  - Test error scenarios and recovery mechanisms
  - Performance test with multiple domains and concurrent requests
  - Test SSE streaming integration with all domains
  - Validate streaming fallback mechanisms
  - Test concurrent streaming sessions
  - _Requirements: All requirements integration testing_

- [ ] 20. Implement domain management system




  - Create DecisionEngine.DomainManager module with CRUD operations for domains
  - Implement domain configuration validation and error handling
  - Add file system operations for persisting domain configurations
  - Implement domain listing, creation, updating, and deletion functionality
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_

- [ ]* 20.1 Write property test for domain list display
  - **Property 31: Domain List Display**
  - **Validates: Requirements 11.1**

- [ ]* 20.2 Write property test for domain detail viewing
  - **Property 32: Domain Detail Viewing**
  - **Validates: Requirements 11.2**

- [ ]* 20.3 Write property test for domain creation validation
  - **Property 33: Domain Creation Validation**
  - **Validates: Requirements 11.3, 11.6, 11.7**

- [ ]* 20.4 Write property test for domain update persistence
  - **Property 34: Domain Update Persistence**
  - **Validates: Requirements 11.4, 11.6**

- [ ]* 20.5 Write property test for domain deletion cleanup
  - **Property 35: Domain Deletion Cleanup**
  - **Validates: Requirements 11.5, 11.7**

- [ ]* 20.6 Write property test for configuration file persistence
  - **Property 36: Configuration File Persistence**
  - **Validates: Requirements 11.6**

- [ ]* 20.7 Write property test for dynamic domain availability
  - **Property 37: Dynamic Domain Availability**
  - **Validates: Requirements 11.7**

- [ ] 21. Enhance RuleConfig for cache management
  - Add cache invalidation functionality to RuleConfig module
  - Implement cache management for dynamic domain reloading
  - Add support for configuration reloading without system restart
  - Ensure thread-safe cache operations for concurrent access
  - _Requirements: 11.7_

- [ ] 22. Create domain management LiveView interface
  - Implement DecisionEngineWeb.DomainManagementLive module
  - Create domain listing view with edit and delete actions
  - Implement domain creation and editing forms
  - Add form validation and error display
  - Create dynamic form fields for signal fields and patterns
  - Add confirmation dialogs for domain deletion
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

- [ ] 23. Create domain management templates and styling
  - Create domain_management_live.html.heex template
  - Implement responsive design for domain management interface
  - Add form components for domain configuration
  - Create pattern and signal field dynamic form components
  - Add CSS styling for domain management interface
  - Implement user-friendly form validation display
  - _Requirements: 11.1, 11.2, 11.3, 11.4_

- [ ] 24. Update router and navigation for domain management
  - Add domain management route to Phoenix router
  - Update navigation to include domain management link
  - Add proper authorization if needed
  - Ensure domain management is accessible from main interface
  - _Requirements: 11.1_

- [ ] 25. Integrate domain management with existing domain selector
  - Update domain selector to dynamically load available domains
  - Ensure domain selector reflects changes made through management interface
  - Add real-time updates when domains are added, modified, or deleted
  - Test integration between domain management and decision processing
  - _Requirements: 11.7_

- [ ] 26. Checkpoint - Ensure all domain management functionality tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 27. Final integration and testing
  - Create end-to-end integration tests for all domains
  - Test domain switching workflows in LiveView
  - Validate configuration reloading functionality
  - Test error scenarios and recovery mechanisms
  - Performance test with multiple domains and concurrent requests
  - Test SSE streaming integration with all domains
  - Validate streaming fallback mechanisms
  - Test concurrent streaming sessions
  - Test domain management integration with decision processing
  - Validate domain management CRUD operations
  - Test real-time domain availability updates
  - _Requirements: All requirements integration testing_

- [ ] 28. Final Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.