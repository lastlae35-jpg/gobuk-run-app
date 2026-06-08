const STATUS_LABELS = {
  done: "완료",
  partial: "일부 완료",
  rest: "휴식",
  skipped: "미실시"
};

const PROFILE_FIELDS = [
  { key: "profile_no", label: "번호", type: "number", placeholder: "예: 1" },
  { key: "nickname", label: "닉네임/이름", type: "text", placeholder: "예: 김거북" },
  { key: "gender", label: "성별", type: "select", options: ["", "남", "여", "기타/미기재"] },
  { key: "birth_year", label: "출생연도", type: "number", placeholder: "예: 1979" },
  { key: "goal_record", label: "목표기록", type: "text", placeholder: "예: 4시간 20분 언더" },
  { key: "vo2max", label: "VO2max", type: "number", step: "0.1", placeholder: "예: 45" },
  { key: "lt_pace", label: "LT페이스", type: "text", placeholder: "예: 5:30/km" },
  { key: "lt_hr", label: "LT심박", type: "number", placeholder: "예: 165" },
  { key: "expected_10k", label: "10K예상", type: "text", placeholder: "예: 55분" },
  { key: "expected_half", label: "하프예상", type: "text", placeholder: "예: 2시간 00분" },
  { key: "expected_full", label: "풀예상", type: "text", placeholder: "예: 4시간 20분" },
  { key: "weekly_available_count", label: "주간 가능횟수", type: "number", placeholder: "예: 3" },
  { key: "personal_jog_days", label: "개인조깅 가능요일", type: "text", placeholder: "예: 월/수/금" },
  { key: "team_training_days", label: "팀훈련 가능요일", type: "text", placeholder: "예: 화/목/일" },
  { key: "pain_yn", label: "통증여부", type: "select", options: ["", "없음", "있음", "가끔 있음"] },
  { key: "current_pain", label: "현재 통증", type: "textarea", placeholder: "예: 오른쪽 무릎 바깥쪽, 달릴 때만" },
  { key: "longrun_weakness", label: "장거리 취약부위", type: "textarea", placeholder: "예: 종아리, 햄스트링, 발바닥" },
  { key: "risk_note", label: "걱정/리스크", type: "textarea", placeholder: "예: 더위, 일정 불규칙, 보급 미숙" },
  { key: "help_request", label: "도움 요청", type: "textarea", placeholder: "예: LSD 페이스 조절, 통증 관리" }
];

const app = document.querySelector("#app");
const config = window.GOBUK_CONFIG || {};
const isConfigured = Boolean(
  config.supabaseUrl &&
  config.supabaseAnonKey &&
  !config.supabaseUrl.includes("YOUR-PROJECT") &&
  !config.supabaseAnonKey.includes("YOUR_PUBLIC")
);
const supabaseClient = isConfigured ? window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey) : null;

const state = {
  token: null,
  member: null,
  plan: [],
  logs: [],
  summary: {},
  profile: {},
  activeView: "dashboard",
  planFilter: "week",
  adminPlanFilter: "week",
  admin: { members: [], summary: [], logs: [], profiles: [] }
};

let globalClickBound = false;

function safe(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
  })[char]);
}

function today() {
  const now = new Date();
  const offset = now.getTimezoneOffset() * 60000;
  return new Date(now.getTime() - offset).toISOString().slice(0, 10);
}

function fmtNum(value, digits = 1) {
  const num = Number(value || 0);
  return num.toLocaleString("ko-KR", {
    maximumFractionDigits: digits,
    minimumFractionDigits: Number.isInteger(num) ? 0 : digits
  });
}

function fmtDate(dateStr) {
  if (!dateStr) return "-";
  const d = new Date(`${dateStr}T00:00:00`);
  return `${d.getFullYear()}.${String(d.getMonth() + 1).padStart(2, "0")}.${String(d.getDate()).padStart(2, "0")}`;
}

function shortDate(dateStr) {
  if (!dateStr) return "-";
  const d = new Date(`${dateStr}T00:00:00`);
  return `${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}`;
}

function monthKey(dateStr) {
  if (!dateStr) return "";
  return String(dateStr).slice(0, 7);
}

function currentMonthKey() {
  return today().slice(0, 7);
}

function monthLabel(key) {
  if (!key) return "-";
  const [year, month] = key.split("-");
  return `${year}년 ${Number(month)}월`;
}

function monthlyMileageRows() {
  const monthly = new Map();
  state.logs.forEach((log) => {
    const km = Number(log.actual_km || 0);
    if (!log.log_date || km <= 0) return;
    const key = monthKey(log.log_date);
    const prev = monthly.get(key) || { month: key, km: 0, count: 0 };
    prev.km += km;
    prev.count += 1;
    monthly.set(key, prev);
  });
  return [...monthly.values()].sort((a, b) => b.month.localeCompare(a.month));
}

function mileageForMonth(key = currentMonthKey()) {
  return monthlyMileageRows().find((row) => row.month === key)?.km || 0;
}

function monthlyMileageHtml() {
  const rows = monthlyMileageRows();
  const currentKey = currentMonthKey();
  if (!rows.length) return `<p class="empty">아직 월 마일리지로 집계할 기록이 없습니다.</p>`;
  return `
    <div class="table-wrap">
      <table>
        <thead><tr><th>월</th><th>마일리지</th><th>입력횟수</th></tr></thead>
        <tbody>
          ${rows.map((row) => `
            <tr class="${row.month === currentKey ? "highlight-row" : ""}">
              <td>${monthLabel(row.month)}${row.month === currentKey ? " <span class='mini-badge'>이번 달</span>" : ""}</td>
              <td>${fmtNum(row.km, 1)} km</td>
              <td>${row.count}회</td>
            </tr>`).join("")}
        </tbody>
      </table>
    </div>`;
}

function weekRange() {
  const d = new Date(`${today()}T00:00:00`);
  const day = d.getDay();
  const start = new Date(d);
  start.setDate(d.getDate() - day);
  const end = new Date(start);
  end.setDate(start.getDate() + 6);
  return [start.toISOString().slice(0, 10), end.toISOString().slice(0, 10)];
}

function toast(message) {
  const el = document.querySelector("#toast");
  if (!el) return alert(message);
  el.textContent = message;
  el.classList.remove("hidden");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => el.classList.add("hidden"), 2300);
}

async function rpc(name, args = {}) {
  if (!supabaseClient) throw new Error("Supabase 설정이 필요합니다.");
  const { data, error } = await supabaseClient.rpc(name, args);
  if (error) throw new Error(error.message || "요청 처리 중 오류가 발생했습니다.");
  return data;
}

function saveSession(payload) {
  state.token = payload.token;
  state.member = payload.member;
  localStorage.setItem("gobukRunSessionV2", JSON.stringify(payload));
}

function restoreSession() {
  try {
    const saved = JSON.parse(localStorage.getItem("gobukRunSessionV2") || "null");
    if (saved?.token && saved?.member) {
      state.token = saved.token;
      state.member = saved.member;
    }
  } catch (_) {
    localStorage.removeItem("gobukRunSessionV2");
  }
}

function clearSession() {
  localStorage.removeItem("gobukRunSessionV2");
  state.token = null;
  state.member = null;
  state.plan = [];
  state.logs = [];
  state.summary = {};
  state.profile = {};
  state.admin = { members: [], summary: [], logs: [], profiles: [] };
}

function init() {
  restoreSession();
  if (state.token && state.member) loadApp().catch((error) => {
    clearSession();
    showLogin();
    toast(error.message);
  });
  else showLogin();
}

function showLogin() {
  app.innerHTML = document.querySelector("#login-template").innerHTML;
  document.querySelector("#config-warning")?.classList.toggle("hidden", isConfigured);
  document.querySelectorAll("[data-auth-tab]").forEach((button) => {
    button.addEventListener("click", () => setAuthTab(button.dataset.authTab));
  });
  document.querySelector("#login-form").addEventListener("submit", onLogin);
  document.querySelector("#signup-form").addEventListener("submit", onSignup);
}

function setAuthTab(tab) {
  const selected = tab === "signup" ? "signup" : "login";
  document.querySelectorAll("[data-auth-tab]").forEach((button) => button.classList.toggle("active", button.dataset.authTab === selected));
  document.querySelector("#login-form")?.classList.toggle("active", selected === "login");
  document.querySelector("#signup-form")?.classList.toggle("active", selected === "signup");
}

async function onLogin(event) {
  event.preventDefault();
  const button = event.submitter;
  button.disabled = true;
  try {
    const name = document.querySelector("#login-name").value.trim();
    const password = document.querySelector("#login-password").value.trim();
    const data = await rpc("login_member", { p_name: name, p_password: password });
    saveSession(data);
    await loadApp();
  } catch (error) {
    toast(error.message);
  } finally {
    button.disabled = false;
  }
}

async function onSignup(event) {
  event.preventDefault();
  const button = event.submitter;
  button.disabled = true;
  try {
    const name = document.querySelector("#signup-name").value.trim();
    const password = document.querySelector("#signup-password").value.trim();
    const confirm = document.querySelector("#signup-password-confirm").value.trim();
    const checked = document.querySelector("#signup-security-check").checked;
    if (password !== confirm) throw new Error("비밀번호 확인이 일치하지 않습니다.");
    if (!checked) throw new Error("가입 전 안내문구 확인이 필요합니다.");
    const data = await rpc("register_member", { p_name: name, p_password: password });
    saveSession(data);
    await loadApp();
    toast("회원가입 완료");
  } catch (error) {
    toast(error.message);
  } finally {
    button.disabled = false;
  }
}

async function loadApp() {
  app.innerHTML = document.querySelector("#main-template").innerHTML;
  document.querySelector("#hello-title").textContent = `${state.member.name}님 훈련 현황`;
  document.querySelectorAll(".admin-only").forEach((el) => el.classList.toggle("hidden", state.member.role !== "admin"));
  bindShellEvents();
  await refreshAll();
}

function bindShellEvents() {
  document.querySelector("#tabs")?.addEventListener("click", (event) => {
    const button = event.target.closest("[data-view]");
    if (button) setView(button.dataset.view);
  });

  document.querySelector("#log-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (event.submitter?.value === "cancel") return;
    const button = event.submitter;
    button.disabled = true;
    try {
      await saveLogFromDialog();
      document.querySelector("#log-dialog")?.close();
      await refreshAll(false);
      toast("훈련 기록 저장 완료");
    } catch (error) {
      toast(error.message);
    } finally {
      button.disabled = false;
    }
  });

  document.querySelector("#plan-date")?.addEventListener("change", (event) => {
    const dayInput = document.querySelector("#plan-day-name");
    if (dayInput && event.target.value) dayInput.value = dayNameFromDate(event.target.value);
  });

  document.querySelectorAll("dialog").forEach((dialog) => {
    dialog.addEventListener("click", (event) => {
      if (event.target === dialog) dialog.close();
    });
  });

  if (!globalClickBound) {
    document.addEventListener("click", handleGlobalClick);
    globalClickBound = true;
  }
}

async function handleGlobalClick(event) {
  const button = event.target.closest("[data-action]");
  if (!button) return;
  const action = button.dataset.action;

  try {
    if (action === "logout") {
      if (state.token) await rpc("logout_member", { p_token: state.token }).catch(() => null);
      clearSession();
      showLogin();
      return;
    }

    if (action === "open-log") {
      openLogDialog(button.dataset.planId || null, button.dataset.date || today());
      return;
    }

    if (action === "close-dialog") {
      const dialogId = button.dataset.dialog;
      const dialog = dialogId ? document.querySelector(`#${dialogId}`) : button.closest("dialog");
      dialog?.close();
      return;
    }

    if (action === "delete-log") {
      const log = state.logs.find((item) => item.id === button.dataset.logId);
      if (!log) return;
      if (!confirm(`${fmtDate(log.log_date)} 기록을 삭제할까요?`)) return;
      await rpc("delete_my_log", { p_token: state.token, p_log_id: log.id });
      await refreshAll(false);
      toast("삭제 완료");
      return;
    }

    if (action === "save-profile") {
      await saveProfile(button);
      return;
    }

    if (action === "change-password") {
      await changePassword(button);
      return;
    }

    if (action === "admin-create-member") {
      await adminCreateMember(button);
      return;
    }

    if (action === "admin-plan-filter") {
      state.adminPlanFilter = button.dataset.filter || "week";
      renderAdmin();
      return;
    }

    if (action === "admin-open-plan-new") {
      openPlanEditor(null);
      return;
    }

    if (action === "admin-open-plan-edit") {
      openPlanEditor(button.dataset.planId);
      return;
    }

    if (action === "admin-save-plan") {
      await adminSavePlan(button);
      return;
    }

    if (action === "admin-delete-plan") {
      await adminDeletePlan(button);
      return;
    }

    if (action === "download-csv") {
      downloadCsv(button.dataset.csv);
    }
  } catch (error) {
    toast(error.message);
  }
}

async function refreshAll(keepView = true) {
  const view = keepView ? state.activeView : state.activeView;
  const tasks = [
    rpc("list_plan", { p_token: state.token }),
    rpc("get_my_logs", { p_token: state.token }),
    rpc("get_my_summary", { p_token: state.token }),
    rpc("get_my_profile", { p_token: state.token })
  ];
  const [plan, logs, summary, profile] = await Promise.all(tasks);
  state.plan = plan || [];
  state.logs = logs || [];
  state.summary = summary || {};
  state.profile = profile || {};

  if (state.member.role === "admin") {
    const [members, adminSummary, adminLogs, adminProfiles] = await Promise.all([
      rpc("admin_list_members", { p_token: state.token }),
      rpc("admin_summary", { p_token: state.token }),
      rpc("admin_all_logs", { p_token: state.token }),
      rpc("admin_profiles", { p_token: state.token })
    ]);
    state.admin = { members: members || [], summary: adminSummary || [], logs: adminLogs || [], profiles: adminProfiles || [] };
  }

  renderAll();
  setView(view);
}

function setView(view) {
  if (view === "admin" && state.member?.role !== "admin") {
    toast("관리자 권한이 필요합니다.");
    view = "dashboard";
  }
  state.activeView = view;
  document.querySelectorAll(".tab").forEach((button) => button.classList.toggle("active", button.dataset.view === view));
  document.querySelectorAll(".view").forEach((section) => section.classList.toggle("active", section.id === `view-${view}`));
}

function renderAll() {
  renderDashboard();
  renderProfile();
  renderPlan();
  renderLogs();
  if (state.member.role === "admin") renderAdmin();
}

function renderDashboard() {
  const s = state.summary || {};
  const thisMonthKm = mileageForMonth();
  const nextPlan = state.plan.find((item) => item.plan_date >= today() && Number(item.planned_km) > 0);
  document.querySelector("#view-dashboard").innerHTML = `
    <div class="kpi-grid">
      ${kpiCard("누적거리", `${fmtNum(s.total_km, 1)} km`, "실제 입력한 총 거리")}
      ${kpiCard("이번 달 마일리지", `${fmtNum(thisMonthKm, 1)} km`, monthLabel(currentMonthKey()))}
      ${kpiCard("거리 달성률", `${fmtNum(s.distance_rate_pct, 1)}%`, `${fmtNum(s.actual_km_until_today, 1)} / ${fmtNum(s.planned_km_until_today, 1)} km`)}
      ${kpiCard("실행률", `${fmtNum(s.execution_rate_pct, 1)}%`, `${s.done_count || 0} / ${s.planned_count || 0}`)}
    </div>
    <section class="card">
      <div class="section-title"><h2>오늘의 요약</h2><button class="small-btn" type="button" data-view="plan" onclick="document.querySelector('[data-view=plan]').click()">훈련표 보기</button></div>
      <p class="muted">실행률은 계획된 훈련 중 <b>완료/일부 완료</b> 처리한 횟수입니다. 거리 달성률은 오늘까지의 계획 거리 대비 실제 누적거리입니다.</p>
      ${nextPlan ? `
        <div class="plan-card">
          <div class="plan-head"><div><div class="plan-date">다음 훈련 ${fmtDate(nextPlan.plan_date)}</div><div class="plan-title">${safe(nextPlan.workout_type || "훈련")}</div></div><span class="pill">${fmtNum(nextPlan.planned_km, 1)}km</span></div>
          <p>${safe(nextPlan.workout || "")}</p>
          <button class="primary-btn" type="button" data-action="open-log" data-plan-id="${nextPlan.id}" data-date="${nextPlan.plan_date}">이 훈련 입력</button>
        </div>` : `<p class="empty">예정된 훈련이 없습니다.</p>`}
    </section>
    <section class="card">
      <div class="section-title"><h2>월 마일리지</h2></div>
      <p class="muted">본인이 입력한 실제 거리 기준으로 월별 마일리지를 집계합니다.</p>
      ${monthlyMileageHtml()}
    </section>
  `;
}

function kpiCard(label, value, sub) {
  return `<section class="kpi-card"><div class="kpi-label">${label}</div><div class="kpi-value">${value}</div><div class="kpi-sub">${sub}</div></section>`;
}

function renderProfile() {
  const fieldsHtml = PROFILE_FIELDS.map((field) => profileFieldHtml(field)).join("");
  document.querySelector("#view-profile").innerHTML = `
    <section class="card">
      <div class="section-title"><h2>내 정보 입력/수정</h2></div>
      <p class="muted">추후 변동되면 언제든 다시 수정해서 저장할 수 있습니다. 비밀번호는 관리자에게도 표시되지 않습니다.</p>
      <form id="profile-form" class="form-grid">${fieldsHtml}</form>
      <div class="form-actions"><button class="primary-btn" type="button" data-action="save-profile">내 정보 저장</button></div>
    </section>
    <section class="card">
      <div class="section-title"><h2>비밀번호 변경</h2></div>
      <div class="security-notice"><b>주의</b><p>이 앱 전용 비밀번호를 사용하세요. 다른 사이트 비밀번호와 같게 쓰지 마세요.</p></div>
      <form id="password-form" class="form-grid">
        <label>현재 비밀번호<input id="current-password" type="password" autocomplete="current-password" /></label>
        <label>새 비밀번호<input id="new-password" type="password" autocomplete="new-password" minlength="4" /></label>
        <label>새 비밀번호 확인<input id="new-password-confirm" type="password" autocomplete="new-password" minlength="4" /></label>
      </form>
      <div class="form-actions"><button class="ghost-btn" type="button" data-action="change-password">비밀번호 변경</button></div>
    </section>
  `;
}

function profileFieldHtml(field) {
  const value = state.profile?.[field.key] ?? "";
  const wide = ["current_pain", "longrun_weakness", "risk_note", "help_request"].includes(field.key) ? "wide" : "";
  if (field.type === "select") {
    return `<label class="${wide}">${field.label}<select data-profile-key="${field.key}">${field.options.map((option) => `<option value="${safe(option)}" ${option === value ? "selected" : ""}>${safe(option || "선택")}</option>`).join("")}</select></label>`;
  }
  if (field.type === "textarea") {
    return `<label class="${wide}">${field.label}<textarea data-profile-key="${field.key}" placeholder="${safe(field.placeholder || "")}">${safe(value)}</textarea></label>`;
  }
  return `<label class="${wide}">${field.label}<input data-profile-key="${field.key}" type="${field.type}" step="${field.step || "1"}" value="${safe(value)}" placeholder="${safe(field.placeholder || "")}" /></label>`;
}

async function saveProfile(button) {
  button.disabled = true;
  try {
    const profile = {};
    document.querySelectorAll("[data-profile-key]").forEach((input) => {
      profile[input.dataset.profileKey] = input.value.trim();
    });
    state.profile = await rpc("upsert_my_profile", { p_token: state.token, p_profile: profile });
    await refreshAll(false);
    toast("내 정보 저장 완료");
  } finally {
    button.disabled = false;
  }
}

async function changePassword(button) {
  const current = document.querySelector("#current-password")?.value.trim();
  const next = document.querySelector("#new-password")?.value.trim();
  const confirmNext = document.querySelector("#new-password-confirm")?.value.trim();
  if (!current || !next) throw new Error("현재 비밀번호와 새 비밀번호를 입력해주세요.");
  if (next !== confirmNext) throw new Error("새 비밀번호 확인이 일치하지 않습니다.");
  button.disabled = true;
  try {
    await rpc("change_my_password", { p_token: state.token, p_current_password: current, p_new_password: next });
    document.querySelector("#password-form")?.reset();
    toast("비밀번호 변경 완료");
  } finally {
    button.disabled = false;
  }
}

function renderPlan() {
  const [weekStart, weekEnd] = weekRange();
  let list = state.plan;
  if (state.planFilter === "today") list = state.plan.filter((item) => item.plan_date === today());
  if (state.planFilter === "week") list = state.plan.filter((item) => item.plan_date >= weekStart && item.plan_date <= weekEnd);
  document.querySelector("#view-plan").innerHTML = `
    <section class="card">
      <div class="section-title"><h2>훈련표</h2></div>
      <div class="plan-filters">
        ${filterButton("week", "이번 주")}
        ${filterButton("today", "오늘")}
        ${filterButton("all", "전체")}
      </div>
    </section>
    ${list.length ? list.map(planCard).join("") : `<section class="card empty">표시할 훈련이 없습니다.</section>`}
  `;
  document.querySelectorAll("[data-filter]").forEach((button) => button.addEventListener("click", () => {
    state.planFilter = button.dataset.filter;
    renderPlan();
  }));
}

function filterButton(value, label) {
  return `<button class="small-btn" type="button" data-filter="${value}" ${state.planFilter === value ? "style='background:#0f766e;color:white'" : ""}>${label}</button>`;
}

function planCard(item) {
  const existing = state.logs.find((log) => log.log_date === item.plan_date);
  const todayClass = item.plan_date === today() ? "today" : "";
  return `
    <article class="plan-card ${todayClass}">
      <div class="plan-head">
        <div>
          <div class="plan-date">${fmtDate(item.plan_date)} (${safe(item.day_name || "")})</div>
          <div class="plan-title">${safe(item.workout_type || "훈련")}</div>
        </div>
        <span class="pill">계획 ${fmtNum(item.planned_km, 1)}km</span>
      </div>
      <div class="plan-meta">
        <span class="pill gray">${safe(item.phase || "")}</span>
        <span class="pill gray">${safe(item.division || "")}</span>
        ${existing ? `<span class="pill warn">입력됨 ${fmtNum(existing.actual_km, 1)}km</span>` : ""}
      </div>
      <p>${safe(item.workout || "")}</p>
      ${item.pace_guide ? `<p class="muted"><b>페이스</b> ${safe(item.pace_guide)}</p>` : ""}
      ${item.coach_note ? `<p class="muted"><b>메모</b> ${safe(item.coach_note)}</p>` : ""}
      <button class="primary-btn" type="button" data-action="open-log" data-plan-id="${item.id}" data-date="${item.plan_date}">${existing ? "기록 수정" : "기록 입력"}</button>
    </article>
  `;
}

function openLogDialog(planId, date) {
  const plan = state.plan.find((item) => item.id === planId) || state.plan.find((item) => item.plan_date === date);
  const log = state.logs.find((item) => item.log_date === (plan?.plan_date || date));
  document.querySelector("#log-plan-title").textContent = plan ? `${fmtDate(plan.plan_date)} · ${plan.workout_type || "훈련"} · 계획 ${fmtNum(plan.planned_km, 1)}km` : "개인 훈련 입력";
  document.querySelector("#log-plan-id").value = plan?.id || "";
  document.querySelector("#log-date").value = log?.log_date || plan?.plan_date || date || today();
  document.querySelector("#log-status").value = log?.status || "done";
  document.querySelector("#log-km").value = log?.actual_km ?? plan?.planned_km ?? "";
  document.querySelector("#log-memo").value = log?.memo || "";
  document.querySelector("#log-dialog").showModal();
}

async function saveLogFromDialog() {
  const planId = document.querySelector("#log-plan-id").value || null;
  const logDate = document.querySelector("#log-date").value;
  const actualKm = Number(document.querySelector("#log-km").value || 0);
  const status = document.querySelector("#log-status").value;
  const memo = document.querySelector("#log-memo").value.trim();
  await rpc("upsert_log", {
    p_token: state.token,
    p_plan_id: planId,
    p_log_date: logDate,
    p_actual_km: actualKm,
    p_status: status,
    p_memo: memo
  });
}

function renderLogs() {
  document.querySelector("#view-logs").innerHTML = `
    <section class="card">
      <div class="section-title"><h2>내 기록</h2><button class="small-btn" type="button" data-action="open-log" data-date="${today()}">개인 기록 추가</button></div>
      <p class="muted">잘못 입력한 기록은 여기서 직접 삭제할 수 있습니다.</p>
    </section>
    ${state.logs.length ? state.logs.map(logCard).join("") : `<section class="card empty">아직 입력한 훈련 기록이 없습니다.</section>`}
  `;
}

function logCard(log) {
  return `
    <article class="log-card">
      <div class="log-head">
        <div>
          <div class="plan-date">${fmtDate(log.log_date)}</div>
          <div class="plan-title">${safe(log.workout_type || "개인 훈련")}</div>
        </div>
        <span class="pill">${fmtNum(log.actual_km, 1)}km</span>
      </div>
      <div class="plan-meta"><span class="status-${safe(log.status)}">${STATUS_LABELS[log.status] || log.status}</span>${log.planned_km ? `<span class="pill gray">계획 ${fmtNum(log.planned_km, 1)}km</span>` : ""}</div>
      ${log.memo ? `<p>${safe(log.memo)}</p>` : ""}
      <div class="form-actions">
        <button class="small-btn" type="button" data-action="open-log" data-plan-id="${log.plan_id || ""}" data-date="${log.log_date}">수정</button>
        <button class="danger-btn" type="button" data-action="delete-log" data-log-id="${log.id}">삭제</button>
      </div>
    </article>
  `;
}

function renderAdmin() {
  document.querySelector("#view-admin").innerHTML = `
    <section class="card admin-create">
      <div class="section-title"><h2>회원 추가</h2></div>
      <div class="form-grid">
        <label>이름<input id="admin-new-name" placeholder="예: 김거북" /></label>
        <label>비밀번호<input id="admin-new-password" placeholder="예: 1111" /></label>
        <label>권한<select id="admin-new-role"><option value="runner">일반회원</option><option value="admin">관리자</option></select></label>
      </div>
      <div class="form-actions"><button class="primary-btn" type="button" data-action="admin-create-member">회원 추가</button></div>
    </section>

    <section class="card">
      <div class="section-title"><h2>훈련표 관리</h2><button class="primary-btn" type="button" data-action="admin-open-plan-new">훈련 추가</button></div>
      <p class="muted">관리자는 웹앱에서 훈련 날짜, 종류, 거리, 훈련 내용, 페이스, 메모를 바로 수정할 수 있습니다. 저장하면 회원 화면에도 즉시 반영됩니다.</p>
      <div class="plan-filters">
        ${adminPlanFilterButton("week", "이번 주")}
        ${adminPlanFilterButton("upcoming", "다가오는 30개")}
        ${adminPlanFilterButton("all", "전체")}
      </div>
      <div class="admin-plan-list">${adminPlanCards()}</div>
    </section>

    <section class="card">
      <div class="section-title"><h2>전체 현황</h2></div>
      <div class="csv-actions">
        <button class="small-btn" type="button" data-action="download-csv" data-csv="summary">현황 CSV</button>
        <button class="small-btn" type="button" data-action="download-csv" data-csv="profiles">회원정보 CSV</button>
        <button class="small-btn" type="button" data-action="download-csv" data-csv="logs">기록 CSV</button>
        <button class="small-btn" type="button" data-action="download-csv" data-csv="plans">훈련표 CSV</button>
      </div>
      <div class="table-wrap">${summaryTable()}</div>
    </section>

    <section class="card">
      <div class="section-title"><h2>회원 정보표</h2></div>
      <div class="table-wrap">${profilesTable()}</div>
    </section>

    <section class="card">
      <div class="section-title"><h2>최근 전체 기록</h2></div>
      <div class="table-wrap">${logsTable()}</div>
    </section>
  `;
}


function adminPlanFilterButton(value, label) {
  return `<button class="small-btn" type="button" data-action="admin-plan-filter" data-filter="${value}" ${state.adminPlanFilter === value ? "style='background:#0f766e;color:white'" : ""}>${label}</button>`;
}

function adminPlanCards() {
  const [weekStart, weekEnd] = weekRange();
  let list = [...state.plan];
  if (state.adminPlanFilter === "week") list = list.filter((item) => item.plan_date >= weekStart && item.plan_date <= weekEnd);
  if (state.adminPlanFilter === "upcoming") list = list.filter((item) => item.plan_date >= today()).slice(0, 30);
  if (!list.length) return `<p class="empty">표시할 훈련표가 없습니다.</p>`;
  return list.map((item) => `
    <article class="plan-card ${item.plan_date === today() ? "today" : ""}">
      <div class="plan-head">
        <div>
          <div class="plan-date">${fmtDate(item.plan_date)} (${safe(item.day_name || "")}) · ${safe(item.phase || "")}</div>
          <div class="plan-title">${safe(item.workout_type || "훈련")}</div>
        </div>
        <span class="pill">${fmtNum(item.planned_km, 1)}km</span>
      </div>
      <div class="plan-meta">
        <span class="pill gray">${safe(item.division || "")}</span>
        <span class="pill gray">${safe(String(item.week_no ?? ""))}주차</span>
      </div>
      <p>${safe(item.workout || "")}</p>
      ${item.pace_guide ? `<p class="muted"><b>페이스</b> ${safe(item.pace_guide)}</p>` : ""}
      ${item.coach_note ? `<p class="muted"><b>메모</b> ${safe(item.coach_note)}</p>` : ""}
      <div class="form-actions">
        <button class="small-btn" type="button" data-action="admin-open-plan-edit" data-plan-id="${item.id}">수정</button>
      </div>
    </article>`).join("");
}

function dayNameFromDate(dateStr) {
  if (!dateStr) return "";
  const names = ["일", "월", "화", "수", "목", "금", "토"];
  const d = new Date(`${dateStr}T00:00:00`);
  return names[d.getDay()] || "";
}

function openPlanEditor(planId) {
  if (state.member?.role !== "admin") return toast("관리자 권한이 필요합니다.");
  const plan = planId ? state.plan.find((item) => item.id === planId) : null;
  document.querySelector("#plan-dialog-title").textContent = plan ? "훈련표 수정" : "훈련 추가";
  document.querySelector("#plan-id").value = plan?.id || "";
  document.querySelector("#plan-week-no").value = plan?.week_no ?? "";
  document.querySelector("#plan-phase").value = plan?.phase || "";
  document.querySelector("#plan-date").value = plan?.plan_date || today();
  document.querySelector("#plan-day-name").value = plan?.day_name || dayNameFromDate(plan?.plan_date || today());
  document.querySelector("#plan-division").value = plan?.division || "";
  document.querySelector("#plan-workout-type").value = plan?.workout_type || "";
  document.querySelector("#plan-planned-km").value = plan?.planned_km ?? 0;
  document.querySelector("#plan-workout").value = plan?.workout || "";
  document.querySelector("#plan-pace-guide").value = plan?.pace_guide || "";
  document.querySelector("#plan-coach-note").value = plan?.coach_note || "";
  document.querySelector("#plan-delete-btn")?.classList.toggle("hidden", !plan);
  document.querySelector("#plan-dialog").showModal();
}

async function adminSavePlan(button) {
  if (state.member?.role !== "admin") throw new Error("관리자 권한이 필요합니다.");
  const payload = {
    p_token: state.token,
    p_plan_id: document.querySelector("#plan-id").value || null,
    p_week_no: Number(document.querySelector("#plan-week-no").value || 0),
    p_phase: document.querySelector("#plan-phase").value.trim(),
    p_plan_date: document.querySelector("#plan-date").value,
    p_day_name: document.querySelector("#plan-day-name").value.trim() || dayNameFromDate(document.querySelector("#plan-date").value),
    p_division: document.querySelector("#plan-division").value.trim(),
    p_workout_type: document.querySelector("#plan-workout-type").value.trim(),
    p_planned_km: Number(document.querySelector("#plan-planned-km").value || 0),
    p_workout: document.querySelector("#plan-workout").value.trim(),
    p_pace_guide: document.querySelector("#plan-pace-guide").value.trim(),
    p_coach_note: document.querySelector("#plan-coach-note").value.trim()
  };
  if (!payload.p_plan_date) throw new Error("훈련 날짜를 입력해주세요.");
  if (payload.p_planned_km < 0) throw new Error("계획 거리는 0 이상이어야 합니다.");
  button.disabled = true;
  try {
    await rpc("admin_save_plan", payload);
    document.querySelector("#plan-dialog")?.close();
    await refreshAll(false);
    toast("훈련표 저장 완료");
  } finally {
    button.disabled = false;
  }
}

async function adminDeletePlan(button) {
  if (state.member?.role !== "admin") throw new Error("관리자 권한이 필요합니다.");
  const planId = document.querySelector("#plan-id").value;
  if (!planId) return;
  const plan = state.plan.find((item) => item.id === planId);
  if (!confirm(`${fmtDate(plan?.plan_date)} 훈련표를 삭제할까요?\n회원이 이미 입력한 기록은 개인 기록으로 남고, 훈련표 연결만 해제됩니다.`)) return;
  button.disabled = true;
  try {
    await rpc("admin_delete_plan", { p_token: state.token, p_plan_id: planId });
    document.querySelector("#plan-dialog")?.close();
    await refreshAll(false);
    toast("훈련표 삭제 완료");
  } finally {
    button.disabled = false;
  }
}

async function adminCreateMember(button) {
  const name = document.querySelector("#admin-new-name").value.trim();
  const password = document.querySelector("#admin-new-password").value.trim();
  const role = document.querySelector("#admin-new-role").value;
  if (!name || !password) throw new Error("이름과 비밀번호를 입력해주세요.");
  button.disabled = true;
  try {
    await rpc("admin_create_member", { p_token: state.token, p_name: name, p_password: password, p_role: role });
    await refreshAll(false);
    toast("회원 추가 완료");
  } finally {
    button.disabled = false;
  }
}

function summaryTable() {
  const rows = state.admin.summary.map((row) => `
    <tr>
      <td>${safe(row.name)}</td><td>${safe(row.role)}</td><td>${fmtNum(row.total_km, 1)}</td><td>${fmtNum(row.distance_rate_pct, 1)}%</td><td>${fmtNum(row.execution_rate_pct, 1)}%</td><td>${row.done_count || 0}/${row.planned_count || 0}</td><td>${row.last_log_date ? fmtDate(row.last_log_date) : "-"}</td>
    </tr>`).join("");
  return `<table><thead><tr><th>이름</th><th>권한</th><th>누적km</th><th>거리달성률</th><th>실행률</th><th>완료/계획</th><th>최근기록</th></tr></thead><tbody>${rows || `<tr><td colspan="7">회원이 없습니다.</td></tr>`}</tbody></table>`;
}

function profilesTable() {
  const rows = state.admin.profiles.map((row) => `
    <tr>
      <td>${safe(row.name)}</td><td>${safe(row.profile_no)}</td><td>${safe(row.nickname)}</td><td>${safe(row.gender)}</td><td>${safe(row.birth_year)}</td><td>${safe(row.goal_record)}</td><td>${safe(row.vo2max)}</td><td>${safe(row.lt_pace)}</td><td>${safe(row.lt_hr)}</td><td>${safe(row.expected_10k)}</td><td>${safe(row.expected_half)}</td><td>${safe(row.expected_full)}</td><td>${safe(row.weekly_available_count)}</td><td>${safe(row.personal_jog_days)}</td><td>${safe(row.team_training_days)}</td><td>${safe(row.pain_yn)}</td><td>${safe(row.current_pain)}</td><td>${safe(row.longrun_weakness)}</td><td>${safe(row.risk_note)}</td><td>${safe(row.help_request)}</td>
    </tr>`).join("");
  return `<table><thead><tr><th>로그인명</th><th>번호</th><th>닉네임/이름</th><th>성별</th><th>출생연도</th><th>목표기록</th><th>VO2max</th><th>LT페이스</th><th>LT심박</th><th>10K예상</th><th>하프예상</th><th>풀예상</th><th>주간가능횟수</th><th>개인조깅요일</th><th>팀훈련요일</th><th>통증여부</th><th>현재통증</th><th>장거리취약</th><th>걱정/리스크</th><th>도움요청</th></tr></thead><tbody>${rows || `<tr><td colspan="20">회원 정보가 없습니다.</td></tr>`}</tbody></table>`;
}

function logsTable() {
  const rows = state.admin.logs.slice(0, 80).map((row) => `
    <tr><td>${fmtDate(row.log_date)}</td><td>${safe(row.member_name)}</td><td>${safe(row.status_label || STATUS_LABELS[row.status] || row.status)}</td><td>${fmtNum(row.actual_km, 1)}</td><td>${safe(row.workout_type || "개인")}</td><td>${safe(row.memo || "")}</td></tr>`
  ).join("");
  return `<table><thead><tr><th>날짜</th><th>이름</th><th>상태</th><th>km</th><th>훈련</th><th>메모</th></tr></thead><tbody>${rows || `<tr><td colspan="6">기록이 없습니다.</td></tr>`}</tbody></table>`;
}

function downloadCsv(type) {
  let rows = [];
  let filename = "gobuk.csv";
  if (type === "summary") {
    rows = state.admin.summary;
    filename = "gobuk_summary.csv";
  } else if (type === "profiles") {
    rows = state.admin.profiles;
    filename = "gobuk_profiles.csv";
  } else if (type === "logs") {
    rows = state.admin.logs;
    filename = "gobuk_logs.csv";
  } else if (type === "plans") {
    rows = state.plan;
    filename = "gobuk_training_plan.csv";
  }
  if (!rows.length) return toast("내보낼 데이터가 없습니다.");
  const headers = Object.keys(rows[0]);
  const csv = [headers.join(","), ...rows.map((row) => headers.map((key) => csvCell(row[key])).join(","))].join("\n");
  const blob = new Blob(["\ufeff" + csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function csvCell(value) {
  const text = String(value ?? "").replace(/"/g, '""');
  return `"${text}"`;
}

init();
