// auth-guard.js
// Include this on any page that requires a logged-in user.
// Redirects to login.html if there is no active Supabase session.

const SUPABASE_URL = 'https://vrgqbyowlfqrtjumzeqq.supabase.co';
const SUPABASE_KEY = 'sb_publishable_PgoMJxVK_CQiyhHoXMunrQ_hgByUSzW';
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

(async function requireAuth(){
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) {
    window.location.href = 'login.html';
  }
})();
