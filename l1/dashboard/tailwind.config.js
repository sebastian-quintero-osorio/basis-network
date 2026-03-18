/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./src/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        basis: {
          cyan: "#00FFCC",
          sky: "#00CCFF",
          mint: "#A7F3D0",
          ice: "#67E8F9",
          periwinkle: "#93C5FD",
          blue: "#7aa5ff",
        },
      },
      fontFamily: {
        sans: ['var(--font-inter)', 'system-ui', '-apple-system', 'sans-serif'],
        mono: ['var(--font-mono)', 'ui-monospace', 'monospace'],
      },
      boxShadow: {
        glass: '0 10px 30px rgba(31, 38, 135, 0.2)',
        'glass-hover': '0 16px 40px rgba(31, 38, 135, 0.25)',
      },
    },
  },
  plugins: [],
};
