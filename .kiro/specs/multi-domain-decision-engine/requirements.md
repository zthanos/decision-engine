# Requirements Document

## Introduction

This feature extends the existing decision engine to support multiple decision domains (Power Platform, Data Platform, Integration Platform) with domain-specific rule configurations, signal schemas, and LLM prompts. The system will maintain separate rule sets and schemas for each domain while providing a unified API and user interface for domain selection and processing.

## Glossary

- **Decision_Engine**: The main system that processes user scenarios and provides architectural recommendations
- **Domain**: A specific area of technology decision-making (e.g., Power Platform, Data Platform)
- **Rule_Config**: JSON configuration files containing domain-specific patterns and decision logic
- **Signals_Schema**: Domain-specific data structure definitions for extracting relevant information from user scenarios
- **LLM_Client**: Component that interfaces with language models for signal extraction and justification generation
- **Pattern**: A specific rule configuration that matches certain signal combinations to produce recommendations

## Requirements

### Requirement 1

**User Story:** As a system architect, I want to select different decision domains, so that I can get specialized recommendations for Power Platform, Data Platform, or Integration Platform scenarios.

#### Acceptance Criteria

1. WHEN the system starts THEN the Decision_Engine SHALL support multiple domain types including power_platform, data_platform, and integration_platform
2. WHEN a user accesses the interface THEN the system SHALL display a domain selection dropdown with available domains
3. WHEN a user selects a domain THEN the system SHALL load the corresponding rule configuration and signal schema
4. WHEN processing a scenario THEN the system SHALL use domain-specific rules and schemas for that processing session
5. WHERE domain expansion is needed THEN the system SHALL support adding new domains without modifying core engine logic

### Requirement 2

**User Story:** As a system administrator, I want domain-specific rule configurations stored in separate files, so that I can maintain and update rules independently for each domain.

#### Acceptance Criteria

1. WHEN the system initializes THEN the Rule_Config SHALL load configuration files from priv/rules/ directory with domain-specific naming
2. WHEN a domain is requested THEN the system SHALL parse the corresponding JSON configuration file containing signals_fields and patterns
3. WHEN rule patterns are defined THEN each pattern SHALL include id, outcome, score, summary, use_when conditions, avoid_when conditions, and typical_use_cases
4. WHEN conditions are evaluated THEN the system SHALL support operators including in, intersects, not_intersects for field matching
5. WHERE configuration errors occur THEN the system SHALL provide clear error messages indicating the problematic domain and rule

### Requirement 3

**User Story:** As a developer, I want domain-specific signal schemas, so that each domain can extract the most relevant information from user scenarios.

#### Acceptance Criteria

1. WHEN a domain is selected THEN the Signals_Schema SHALL provide the appropriate schema module for that domain
2. WHEN signal extraction occurs THEN the system SHALL use domain-specific field definitions and enumerated values
3. WHEN schema validation happens THEN the system SHALL apply domain-specific defaults and validation rules
4. WHEN new domains are added THEN the system SHALL support creating new schema modules without modifying existing ones
5. WHERE schema conflicts arise THEN the system SHALL isolate domain schemas to prevent cross-domain interference

### Requirement 4

**User Story:** As an AI system, I want domain-aware LLM prompts, so that I can provide more accurate signal extraction and recommendations based on domain-specific patterns.

#### Acceptance Criteria

1. WHEN extracting signals THEN the LLM_Client SHALL receive domain context, schema module, and rule configuration
2. WHEN building extraction prompts THEN the system SHALL include domain-specific field descriptions and pattern summaries
3. WHEN generating prompts THEN the system SHALL instruct the LLM to align signal extraction with the most appropriate domain patterns
4. WHEN validation fails THEN the system SHALL provide domain-specific retry prompts with corrective guidance
5. WHERE justification is needed THEN the system SHALL generate domain-aware explanations referencing relevant patterns

### Requirement 5

**User Story:** As a system integrator, I want a unified API that handles domain selection, so that the existing DecisionEngine interface remains clean while supporting multiple domains.

#### Acceptance Criteria

1. WHEN processing scenarios THEN the DecisionEngine SHALL accept domain parameter alongside scenario and configuration
2. WHEN domain processing occurs THEN the system SHALL automatically load appropriate schema modules and rule configurations
3. WHEN results are returned THEN the system SHALL include domain information in the response structure
4. WHEN errors occur THEN the system SHALL provide domain-specific error context and recovery suggestions
5. WHERE backward compatibility is required THEN the system SHALL maintain existing API signatures with sensible domain defaults

### Requirement 6

**User Story:** As a user interface component, I want domain selection integrated into the LiveView, so that users can seamlessly switch between different decision domains.

#### Acceptance Criteria

1. WHEN the interface loads THEN the LiveView SHALL display domain selection controls with current domain highlighted
2. WHEN domain changes occur THEN the system SHALL update the interface state without losing user input
3. WHEN scenarios are processed THEN the system SHALL use the currently selected domain for processing
4. WHEN results are displayed THEN the interface SHALL clearly indicate which domain was used for the decision
5. WHERE domain-specific help is needed THEN the system SHALL provide contextual information about each domain's purpose

### Requirement 7

**User Story:** As a rule engine, I want to evaluate patterns generically, so that I can process any domain's rule configuration without domain-specific logic.

#### Acceptance Criteria

1. WHEN evaluating rules THEN the RuleEngine SHALL process signals and rule_config parameters without domain knowledge
2. WHEN matching patterns THEN the system SHALL evaluate use_when and avoid_when conditions using generic condition evaluation
3. WHEN calculating scores THEN the system SHALL apply pattern scoring consistently across all domains
4. WHEN determining best matches THEN the system SHALL use the same matching algorithm regardless of domain
5. WHERE pattern complexity varies THEN the system SHALL handle different condition structures uniformly

### Requirement 8

**User Story:** As a configuration loader, I want to dynamically load domain configurations, so that new domains can be added without system restarts.

#### Acceptance Criteria

1. WHEN domain configurations are requested THEN the RuleConfig SHALL load JSON files using domain-based file naming conventions
2. WHEN parsing configurations THEN the system SHALL validate JSON structure and provide meaningful error messages
3. WHEN file access fails THEN the system SHALL handle missing configuration files gracefully with appropriate fallbacks
4. WHEN configurations change THEN the system SHALL support reloading without requiring application restart
5. WHERE configuration caching is beneficial THEN the system SHALL implement efficient caching with invalidation support

### Requirement 9

**User Story:** As a user, I want LLM responses rendered as formatted markdown, so that I can easily read structured recommendations with proper formatting, lists, and emphasis.

#### Acceptance Criteria

1. WHEN the LLM_Client generates justification text THEN the system SHALL support markdown formatting in the response content
2. WHEN displaying LLM responses in the interface THEN the system SHALL render markdown content as formatted HTML with proper styling
3. WHEN markdown content includes lists, headers, or emphasis THEN the system SHALL preserve the formatting structure and visual hierarchy
4. WHEN rendering markdown THEN the system SHALL sanitize content to prevent XSS attacks while preserving safe formatting elements
5. WHERE markdown parsing fails THEN the system SHALL gracefully fall back to displaying the raw text content

### Requirement 10

**User Story:** As a user, I want to receive LLM responses in real-time through streaming, so that I can see the recommendation being generated progressively instead of waiting for the complete response.

#### Acceptance Criteria

1. WHEN processing a scenario THEN the system SHALL establish a Server-Sent Events (SSE) connection to stream LLM responses in real-time
2. WHEN the LLM generates response content THEN the system SHALL stream partial content chunks as they become available
3. WHEN streaming LLM content THEN the system SHALL render and display each markdown chunk progressively in the user interface
4. WHEN the LLM response is complete THEN the system SHALL send a completion event and close the SSE stream
5. WHEN SSE connection fails or is unavailable THEN the system SHALL gracefully fall back to traditional request-response processing
6. WHEN multiple users are processing scenarios simultaneously THEN the system SHALL maintain separate SSE streams for each user session
7. WHEN a user navigates away or cancels processing THEN the system SHALL properly clean up the SSE connection and stop LLM processing

### Requirement 11

**User Story:** As a system administrator, I want to manage decision domains through a LiveView interface, so that I can view, add, edit, and delete domains without directly modifying configuration files.

#### Acceptance Criteria

1. WHEN accessing the domain management interface THEN the system SHALL display a list of all existing domains with their current configurations
2. WHEN viewing domain details THEN the system SHALL show domain name, description, available signal fields, and configured patterns
3. WHEN creating a new domain THEN the system SHALL provide a form to define domain name, signal schema, and initial rule patterns
4. WHEN editing an existing domain THEN the system SHALL allow modification of domain configuration while preserving data integrity
5. WHEN deleting a domain THEN the system SHALL remove the domain configuration and update the domain selector options
6. WHEN domain changes are saved THEN the system SHALL persist changes to the appropriate configuration files in priv/rules/
7. WHEN domain configurations are modified THEN the changes SHALL be immediately available in the decision domain selector without system restart
