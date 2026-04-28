function ensureExportOrgAccess(user, orgId) {
  if (!user) throw new Error("Forbidden");
  ensureAccountAdminCanAccessBrDeckOrg({ user }, orgId);
}

async function exportJob(req, res) {
  ensureExportOrgAccess(user, jobOrgId);  // line 467 in real file
}
async function exportJobs(req, res) {
  jobs.forEach(j => ensureExportOrgAccess(user, j.orgId));  // line 582
}
async function exportRun(req, res) {
  ensureExportOrgAccess(user, runOrgId);  // line 679
}
async function exportRunWithPreview(req, res) {
  ensureExportOrgAccess(user, runWithPreviewOrgId);  // line 765
}
