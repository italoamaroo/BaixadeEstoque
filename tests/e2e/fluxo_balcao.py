"""Teste ponta a ponta do balcão: almoxarife (leitor HID simulado) + tablet do solicitante."""
import os
import re
from playwright.sync_api import sync_playwright, expect

BASE = os.environ.get('E2E_BASE', 'http://localhost:5173')
OUT = os.environ.get('E2E_OUT', 'tests/e2e/capturas')
os.makedirs(OUT, exist_ok=True)


def login(page, email):
    page.goto(f'{BASE}/login')
    page.get_by_label('E-mail').fill(email)
    page.get_by_label('Senha').fill('teste123')
    page.get_by_role('button', name='Entrar').click()


def bipar(page, code, focus_outside=False):
    """Simula o leitor HID: digita rápido e termina com Enter."""
    if focus_outside:
        page.get_by_role('heading', name='Materiais separados').click()
    page.keyboard.type(code, delay=8)
    page.keyboard.press('Enter')


with sync_playwright() as p:
    browser = p.chromium.launch(args=['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'])
    almox_ctx = browser.new_context(viewport={'width': 1366, 'height': 900})
    tab_ctx = browser.new_context(viewport={'width': 1024, 'height': 768}, permissions=['camera'])
    a = almox_ctx.new_page()
    t = tab_ctx.new_page()

    # Almoxarife abre a separação
    login(a, 'almox.mur@teste.local')
    a.wait_for_url(re.compile(r'.*/$'))
    a.goto(f'{BASE}/balcao')
    a.get_by_placeholder('Nome ou matrícula do funcionário').fill('José')
    a.get_by_role('button', name=re.compile('José Carlos da Silva')).click()
    expect(a.get_by_text(re.compile('DEMO-CT-001 – Coleta domiciliar'))).to_be_visible()  # contrato fixo
    a.get_by_label('Setor').select_option(label='Manutenção mecânica')
    # escolhe o tablet na lista (sem código)
    expect(a.get_by_label('Tablet do solicitante')).to_contain_text('Tablet Balcão Muribeca', timeout=10000)
    a.get_by_label('Tablet do solicitante').select_option(label='Tablet Balcão Muribeca — livre')
    a.screenshot(path=f'{OUT}/b01_abrir.png', full_page=True)
    a.get_by_role('button', name='Abrir separação').click()
    a.wait_for_url(re.compile(r'.*/balcao/[0-9a-f-]{36}$'))
    expect(a.get_by_text(re.compile('Tablet conectado: Tablet Balcão Muribeca'))).to_be_visible(timeout=10000)

    # Tablet faz login (vai direto para /terminal) e já mostra a separação, sem digitar código
    login(t, 'tablet.mur@teste.local')
    t.wait_for_url(re.compile(r'.*/terminal$'))
    expect(t.get_by_text('Aguardando o almoxarife bipar os materiais')).to_be_visible(timeout=10000)

    # Leituras pelo leitor (campo em foco)
    a.locator('#balcao-leitura').click()
    bipar(a, 'MAT-DEMO000001')
    expect(a.get_by_text('Material incluído')).to_be_visible(timeout=10000)
    bipar(a, 'MAT-DEMO000001')  # bipada dupla acidental
    expect(a.get_by_text('Leitura repetida ignorada')).to_be_visible(timeout=5000)
    a.wait_for_timeout(1700)
    bipar(a, 'MAT-DEMO000001')
    expect(a.get_by_role('dialog').get_by_text('Item já incluído nesta ME')).to_be_visible(timeout=10000)
    a.screenshot(path=f'{OUT}/b02_ja_incluido.png')
    a.get_by_role('button', name=re.compile(r'^Somar')).click()
    expect(a.get_by_text('Quantidade somada')).to_be_visible(timeout=10000)
    # foco fora do campo: o ouvinte global captura a leitura
    a.wait_for_timeout(400)
    bipar(a, 'MAT-DEMO000002', focus_outside=True)
    expect(a.get_by_text('Material incluído')).to_be_visible(timeout=10000)
    expect(a.locator('tbody tr')).to_have_count(2, timeout=10000)
    bipar(a, 'MAT-NAOEXISTE1')
    expect(a.get_by_text('QR Code não encontrado')).to_be_visible(timeout=10000)
    expect(a.get_by_text('Código lido: MAT-NAOEXISTE1.', exact=False)).to_be_visible()
    a.screenshot(path=f'{OUT}/b03_almoxarife_lendo.png', full_page=True)
    # foco voltou sozinho para o campo
    a.wait_for_timeout(1300)
    assert a.evaluate("document.activeElement && document.activeElement.id") == 'balcao-leitura', 'foco não voltou ao campo de leitura'

    # Tablet acompanha
    expect(t.get_by_text('Filtro de óleo')).to_be_visible(timeout=10000)
    expect(t.get_by_text('Óleo lubrificante')).to_be_visible(timeout=10000)
    expect(t.get_by_role('button', name='CONFIRMAR ME')).to_have_count(0)
    t.screenshot(path=f'{OUT}/b04_tablet_acompanhando.png', full_page=True)

    # Finalizar separação
    a.get_by_role('button', name='FINALIZAR SEPARAÇÃO').click()
    a.get_by_role('button', name='Finalizar', exact=True).click()
    expect(a.get_by_text('Separação finalizada: aguardando o solicitante confirmar no tablet')).to_be_visible(timeout=10000)
    expect(a.locator('#balcao-leitura')).to_have_count(0)

    # Tablet confirma
    expect(t.get_by_role('button', name='CONFIRMAR ME')).to_be_visible(timeout=10000)
    t.get_by_role('button', name='CONFIRMAR ME').click()
    expect(t.get_by_text('Confira a sua retirada')).to_be_visible()
    t.screenshot(path=f'{OUT}/b05_tablet_resumo.png')
    t.get_by_role('button', name='Está correto, confirmar').click()
    expect(t.get_by_text('1 de 2 · Foto do solicitante')).to_be_visible(timeout=10000)
    expect(t.get_by_role('button', name='Usar esta foto')).to_be_disabled()
    t.wait_for_timeout(1500)
    print('VIDEO', t.evaluate("(() => { const v = document.querySelector('[role=dialog] video'); return v ? [v.videoWidth, v.readyState, !!v.srcObject, v.srcObject && v.srcObject.active, v.paused].join(',') : 'sem video' })()"))
    t.get_by_role('button', name='Tirar foto').click(timeout=15000)
    t.screenshot(path=f'{OUT}/b05b_tablet_foto.png')
    t.get_by_role('button', name='Usar esta foto').click()
    expect(t.get_by_text('2 de 2 · Assine para confirmar a retirada')).to_be_visible()
    canvas = t.locator('canvas')
    box = canvas.bounding_box()
    t.mouse.move(box['x'] + 30, box['y'] + box['height'] / 2)
    t.mouse.down()
    for i in range(1, 50):
        t.mouse.move(box['x'] + 30 + i * 6, box['y'] + box['height'] / 2 + (20 if i % 8 < 4 else -20))
    t.mouse.up()
    t.screenshot(path=f'{OUT}/b06_tablet_assinatura.png')
    t.get_by_role('button', name='Confirmar ME', exact=True).click()
    t.wait_for_timeout(3000)
    t.screenshot(path=f'{OUT}/b06b_apos_confirmar.png')
    expect(t.get_by_text('ME confirmada').first).to_be_visible(timeout=15000)
    t.screenshot(path=f'{OUT}/b07_tablet_confirmada.png', full_page=True)

    expect(a.get_by_text(re.compile('ME confirmada pelo solicitante em'))).to_be_visible(timeout=10000)
    a.screenshot(path=f'{OUT}/b08_almoxarife_confirmada.png', full_page=True)
    # almoxarife não vê a foto no detalhe da ME
    a.get_by_role('link', name='Ver detalhes da ME').click()
    expect(a.get_by_text('Materiais (')).to_be_visible(timeout=10000)
    a.wait_for_timeout(1500)
    assert a.get_by_text('Foto do solicitante').count() == 0, 'almoxarife não deveria ver a foto'
    me_url = a.url
    almox_ctx.close()
    # gestor vê a foto
    g_ctx = browser.new_context(viewport={'width': 1366, 'height': 900})
    g = g_ctx.new_page()
    login(g, 'gestor@teste.local')
    g.wait_for_url(re.compile(r'.*/$'))
    g.goto(me_url)
    expect(g.get_by_text('Foto do solicitante')).to_be_visible(timeout=10000)
    g.get_by_role('button', name='Ver foto').click()
    expect(g.get_by_alt_text('Foto do solicitante')).to_be_visible(timeout=10000)
    g.wait_for_function("document.querySelector('img[alt=\"Foto do solicitante\"]').naturalWidth > 0", timeout=10000)
    g.screenshot(path=f'{OUT}/b09_gestor_foto.png', full_page=True)
    print('OK')
    browser.close()
