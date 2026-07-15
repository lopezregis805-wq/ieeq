// sidebar.js — abre/cierra la barra lateral en pantallas pequeñas.
(function () {
    var sidebar = document.getElementById('ieeqSidebar');
    var backdrop = document.getElementById('ieeqSidebarBackdrop');
    var toggle = document.getElementById('ieeqSidebarToggle');
    if (!sidebar || !backdrop || !toggle) return;

    function abrir() {
        sidebar.classList.add('show');
        backdrop.classList.add('show');
    }
    function cerrar() {
        sidebar.classList.remove('show');
        backdrop.classList.remove('show');
    }

    toggle.addEventListener('click', function () {
        if (sidebar.classList.contains('show')) { cerrar(); } else { abrir(); }
    });
    backdrop.addEventListener('click', cerrar);
    sidebar.querySelectorAll('.nav-link').forEach(function (link) {
        link.addEventListener('click', cerrar);
    });
    window.addEventListener('resize', function () {
        if (window.innerWidth >= 992) cerrar();
    });
})();
