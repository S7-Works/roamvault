/* @refresh reload */
import { render } from "solid-js/web";
import { Router, Route } from "@solidjs/router";
import "./index.css";
import App from "./App.tsx";
import Upload from "./Upload.tsx";

const root = document.getElementById("root")!;

render(
  () => (
    <Router>
      <Route path="/" component={Upload} />
      <Route path="/view/:id" component={App} />
    </Router>
  ),
  root
);
