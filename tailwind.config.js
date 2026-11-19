/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          50: '#f3f8ef', 100: '#e4efdc', 200: '#caddbd', 300: '#a8c795', 400: '#80ad68',
          500: '#669e50', 600: '#4e803d', 700: '#3d6532', 800: '#33522c', 900: '#2b4426', 950: '#152510',
        },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial', 'sans-serif'],
      },
      boxShadow: {
        card: '0 1px 2px rgba(16,24,40,.05), 0 1px 3px rgba(16,24,40,.06)',
      },
    },
  },
  plugins: [],
};
