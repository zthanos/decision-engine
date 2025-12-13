module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/decision_engine_web.ex",
    "../lib/decision_engine_web/**/*.*ex"
  ],
  theme: {
    extend: {},
  },
  plugins: [
    require("daisyui"),
    // Add Heroicons plugin if available
    function({ addUtilities }) {
      // This will be enhanced when Heroicons CSS is properly loaded
      addUtilities({
        '.hero-icon': {
          'display': 'inline-block',
          'width': '1.25rem',
          'height': '1.25rem',
          'flex-shrink': '0',
        }
      })
    }
  ],
  daisyui: {
    themes: [
      {
        light: {
          ...require("daisyui/src/theming/themes")["light"],
          primary: "#570df8",
          secondary: "#f000b8",
          accent: "#37cdbe",
          neutral: "#3d4451",
          "base-100": "#ffffff",
        },
      },
      "dark",
      "cupcake",
      "cyberpunk",
    ],
  },
}