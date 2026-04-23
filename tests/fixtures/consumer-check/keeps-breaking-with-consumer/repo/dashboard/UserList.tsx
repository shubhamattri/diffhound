import { useEffect } from "react";

export function UserList() {
  useEffect(() => {
    fetch("/api/users").then((r) => r.json());
  }, []);
  return null;
}
