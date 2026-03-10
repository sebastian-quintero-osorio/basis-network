/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./src/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        basis: {
          cyan: "#00C8AA",
          teal: "#0CF5C8",
          purple: "#8B5CF6",
          navy: "#1A1A2E",
          slate: "#64748B",
          faint: "#94A3B8",
        },
      },
      fontFamily: {
        sans: ['var(--font-inter)', 'system-ui', '-apple-system', 'sans-serif'],
      },
    },
  },
  plugins: [],
};
