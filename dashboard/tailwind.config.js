/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./src/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        basis: {
          primary: "#E84142",
          dark: "#1A1A2E",
          darker: "#0F0F1A",
          accent: "#00D4AA",
          surface: "#16213E",
          border: "#2A2A4A",
        },
      },
    },
  },
  plugins: [],
};
