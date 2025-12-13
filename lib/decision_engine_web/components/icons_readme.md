# Icon System Documentation

## Overview

The Decision Engine application uses a robust icon system that provides proper fallback mechanisms for missing icon resources. The system is built around Heroicons with comprehensive fallback support to ensure icons are always visible and functional.

## Components

### 1. Icons Module (`DecisionEngineWeb.Components.Icons`)

The main module that provides icon components with fallback support.

#### Available Components

- `icon/1` - Basic icon with optional fallback text
- `icon_with_fallback/1` - Icon with explicit fallback text display
- `icon_button/1` - Button component with icon and automatic fallback

### 2. CSS System (`assets/css/app.css`)

Provides fallback styling and ensures icons display correctly even when Heroicons assets fail to load.

### 3. JavaScript Integration (`assets/js/heroicons.js`)

Dynamically loads SVG content for icons and handles real-time icon updates in LiveView.

## Usage Examples

### Basic Icon

```elixir
<.icon name="home" class="w-5 h-5" />
<.icon name="plus" class="w-4 h-4" fallback_text="+" />
```

### Icon with Explicit Fallback

```elixir
<.icon_with_fallback name="home" fallback_text="🏠" class="w-5 h-5" />
<.icon_with_fallback name="trash" fallback_text="🗑" class="w-4 h-4" />
```

### Icon Button

```elixir
<!-- Icon only button -->
<.icon_button name="plus" phx-click="add_item" />

<!-- Icon with text button -->
<.icon_button name="trash" text="Delete" class="btn btn-error" phx-click="delete" />

<!-- Custom styling -->
<.icon_button 
  name="sparkles" 
  text="Generate" 
  class="btn btn-info" 
  icon_class="w-5 h-5"
  phx-click="generate" 
/>
```

## Available Icons

The system includes fallback support for these common icons:

| Icon Name | Fallback | Description |
|-----------|----------|-------------|
| `home` | 🏠 | Home/House icon |
| `plus` | + | Add/Plus icon |
| `trash` | 🗑 | Delete/Trash icon |
| `pencil` | ✏ | Edit/Pencil icon |
| `x-mark` | ✕ | Close/X icon |
| `cog-6-tooth` | ⚙ | Settings/Gear icon |
| `clock` | 🕐 | Time/Clock icon |
| `building-office` | 🏢 | Building/Office icon |
| `sparkles` | ✨ | AI/Magic icon |
| `arrow-path` | ↻ | Refresh/Reload icon |
| `ellipsis-vertical` | ⋮ | More options icon |
| `chevron-up` | ▲ | Expand/Up arrow |
| `chevron-down` | ▼ | Collapse/Down arrow |
| `table-cells` | 📊 | Table/Grid icon |
| `information-circle` | ℹ | Information icon |
| `exclamation-triangle` | ⚠ | Warning icon |
| `signal` | 📶 | Signal/Strength icon |
| `puzzle-piece` | 🧩 | Component/Puzzle icon |
| `eye` | 👁 | View/Eye icon |
| `light-bulb` | 💡 | Idea/Bulb icon |
| `check` | ✓ | Checkmark icon |

## Fallback Mechanism

The icon system provides multiple layers of fallback:

1. **Primary**: Heroicons SVG loaded via JavaScript
2. **CSS Fallback**: CSS `::before` pseudo-elements with Unicode characters
3. **Component Fallback**: Explicit fallback text in component templates
4. **Default Fallback**: Generic bullet point (•) for unknown icons

## Integration with LiveView

The system automatically handles LiveView updates through JavaScript hooks:

```javascript
// Icons are automatically loaded when:
// - Page loads
// - LiveView connects
// - LiveView updates content
// - Navigation occurs
```

## Accessibility Features

- Proper ARIA attributes for screen readers
- Semantic fallback text for all icons
- High contrast mode support
- Keyboard navigation support
- Print-friendly fallbacks

## Performance Considerations

- Icons are loaded asynchronously via JavaScript
- CSS fallbacks ensure immediate visibility
- Minimal impact on initial page load
- Efficient DOM updates for LiveView changes

## Testing

The icon system includes comprehensive tests:

- Unit tests for all components
- Integration tests with LiveView
- Fallback mechanism validation
- Accessibility compliance testing

Run tests with:

```bash
mix test test/decision_engine_web/components/icons_test.exs
mix test test/decision_engine_web/components/icon_integration_test.exs
```

## Troubleshooting

### Icons Not Displaying

1. Check browser console for JavaScript errors
2. Verify Heroicons dependency is installed
3. Ensure CSS is properly loaded
4. Check that fallback text is configured

### Performance Issues

1. Limit the number of icons per page
2. Use CSS-only fallbacks for critical icons
3. Consider icon sprite sheets for heavy usage

### Accessibility Issues

1. Ensure all icons have proper fallback text
2. Use semantic HTML structure
3. Test with screen readers
4. Verify keyboard navigation works

## Migration from Raw Hero Classes

To migrate existing code from raw `hero-*` classes:

```elixir
# Before
<span class="hero-home w-5 h-5" aria-hidden="true"></span>

# After
<.icon name="home" class="w-5 h-5" aria_hidden={true} />

# Button Before
<button phx-click="action">
  <span class="hero-plus w-4 h-4"></span>
  Add Item
</button>

# Button After
<.icon_button name="plus" text="Add Item" phx-click="action" />
```

## Adding New Icons

1. Add SVG content to `assets/js/heroicons.js`
2. Add CSS fallback to `assets/css/app.css`
3. Update fallback mapping in `icon_button/1` function
4. Add to available icons list in documentation
5. Write tests for the new icon

## Browser Support

- Modern browsers: Full SVG support
- Legacy browsers: CSS fallback support
- No JavaScript: CSS fallback support
- Screen readers: Semantic fallback text