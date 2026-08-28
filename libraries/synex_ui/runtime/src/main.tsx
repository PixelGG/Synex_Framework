import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import '@fontsource-variable/ibm-plex-sans';
import '@fontsource-variable/jetbrains-mono';
import '../../src/styles.css';
import './runtime.css';
import { RuntimeApp } from './RuntimeApp';

const root = document.getElementById('root');
if (!root) throw new Error('synex_ui root element missing');

createRoot(root).render(
  <StrictMode>
    <RuntimeApp />
  </StrictMode>,
);
