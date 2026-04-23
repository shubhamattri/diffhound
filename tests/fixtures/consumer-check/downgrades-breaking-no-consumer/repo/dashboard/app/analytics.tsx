import { useEffect } from "react";

export function Analytics() {
  useEffect(() => {
    fetch("/api/analytics/metrics").then((r) => r.json());
    fetch("/api/analytics/trends").then((r) => r.json());
  }, []);
  return null;
}
