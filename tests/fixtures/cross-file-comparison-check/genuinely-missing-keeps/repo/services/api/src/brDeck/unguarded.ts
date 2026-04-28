export function handleSomething(req, res) {
  const user = req.user;
  doStuff(user, req.body);
  res.json({ ok: true });
}
