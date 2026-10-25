const year = document.querySelector('#year');
if (year) year.textContent = new Date().getFullYear();

const licenseToggle = document.querySelector('[data-license-toggle]');
if (licenseToggle) {
  licenseToggle.hidden = false;
  licenseToggle.setAttribute('aria-expanded', 'false');
  licenseToggle.addEventListener('click', () => {
    const expanded = licenseToggle.getAttribute('aria-expanded') !== 'true';
    for (const notice of document.querySelectorAll('.license-text')) notice.open = expanded;
    licenseToggle.setAttribute('aria-expanded', String(expanded));
    licenseToggle.textContent = expanded ? 'Collapse license texts' : 'Expand license texts';
  });
}

// Progressive enhancement: all content stays visible without JavaScript.
if ('IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    }
  }, { threshold: 0.08 });
  for (const element of document.querySelectorAll('.reveal')) {
    element.classList.add('reveal-ready');
    observer.observe(element);
  }
}
