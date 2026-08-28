import React from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/ibm-plex-sans";
import "@fontsource-variable/jetbrains-mono";
import "../../src/styles.css";
import "./design-lab.css";
import { DesignLab } from "./DesignLab";

const root = document.getElementById("root");

if (!root) throw new Error("Design Lab root is missing");

createRoot(root).render(
  <React.StrictMode>
    <DesignLab />
  </React.StrictMode>,
);
