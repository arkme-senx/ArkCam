const header = document.querySelector('[data-header]');
const menuToggle = document.querySelector('[data-menu-toggle]');
const nav = document.querySelector('[data-nav]');
const dialog = document.querySelector('[data-dialog]');
const form = document.querySelector('[data-waitlist-form]');
const formStatus = document.querySelector('[data-form-status]');

const setMenu = (open) => {
  menuToggle?.setAttribute('aria-expanded', String(open));
  menuToggle?.setAttribute('aria-label', open ? '关闭导航' : '打开导航');
  nav?.classList.toggle('is-open', open);
};

menuToggle?.addEventListener('click', () => setMenu(!nav.classList.contains('is-open')));
nav?.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => setMenu(false)));

document.querySelectorAll('[data-open-waitlist]').forEach((button) => {
  button.addEventListener('click', () => {
    formStatus.textContent = '';
    form?.reset();
    dialog?.showModal();
    dialog?.querySelector('input')?.focus();
  });
});

document.querySelectorAll('[data-close-waitlist]').forEach((button) => {
  button.addEventListener('click', () => dialog?.close());
});

dialog?.addEventListener('click', (event) => {
  if (event.target === dialog) dialog.close();
});

form?.addEventListener('submit', (event) => {
  event.preventDefault();
  const email = new FormData(form).get('email');
  formStatus.textContent = `已记下 ${email}，开放体验时见。`;
  form.reset();
});

document.querySelectorAll('[data-swap]').forEach((button) => {
  button.addEventListener('click', () => {
    const editor = button.closest('[data-editor]');
    if (!editor) return;
    const isFrontPrimary = editor.dataset.frontPrimary === 'true';
    editor.dataset.frontPrimary = String(!isFrontPrimary);
  });
});

const updateHeader = () => header?.classList.toggle('is-scrolled', window.scrollY > 16);
updateHeader();
window.addEventListener('scroll', updateHeader, { passive: true });

const observer = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) {
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    }
  });
}, { threshold: 0.13 });

document.querySelectorAll('.reveal').forEach((element) => observer.observe(element));
