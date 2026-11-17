"""Teste ponta a ponta: contrato e local fixos + ME emergencial no balcão (somente controle)."""
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


def bipar(page, code):
    page.keyboard.type(code, delay=8)
    page.keyboard.press('Enter')


with sync_playwright() as p:
    browser = p.chromium.launch(args=['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'])
    almox_ctx = browser.new_context(viewport={'width': 1366, 'height': 1000})
    tab_ctx = browser.new_context(viewport={'width': 1024, 'height': 768}, permissions=['camera'])
    a = almox_ctx.new_page()
    t = tab_ctx.new_page()

    # Almoxarife abre separação emergencial: contrato e local já fixos
    login(a, 'almox.mur@teste.local')
    a.wait_for_url(re.compile(r'.*/$'))
    a.goto(f'{BASE}/balcao')
    a.get_by_placeholder('Nome ou matrícula do funcionário').fill('José')
    a.get_by_role('button', name=re.compile('José Carlos da Silva')).click()
    expect(a.get_by_text(re.compile('DEMO-CT-001 – Coleta domiciliar'))).to_be_visible()
    expect(a.get_by_text('Contrato fixo (definido em Parâmetros).')).to_be_visible()
    assert a.get_by_label('Contrato').count() == 0, 'contrato não deveria ser editável'
    assert a.get_by_label('Local de aplicação').count() == 0, 'local de aplicação não deveria ser editável'
    a.get_by_label('Setor').select_option(label='Manutenção mecânica')
    a.get_by_label('Ativo fixo (AF)').fill('AF-0099')
    a.get_by_label(re.compile('Retirada emergencial')).check()
    expect(a.get_by_text('ME emergencial: depois da confirmação fica concluída, só para controle.')).to_be_visible()
    a.get_by_label('Tablet do solicitante').select_option(label='Tablet Balcão Muribeca — livre')
    a.get_by_role('button', name='Abrir separação').click()
    expect(a.get_by_text('Informe o motivo da emergência (mínimo de 5 caracteres).')).to_be_visible()
    a.get_by_label(re.compile('Motivo da emergência')).fill('Caminhão parado na rota, fora do horário')
    a.screenshot(path=f'{OUT}/e01_abrir_emergencial.png', full_page=True)
    a.get_by_role('button', name='Abrir separação').click()
    a.wait_for_url(re.compile(r'.*/balcao/[0-9a-f-]{36}$'))
    expect(a.get_by_text('Emergencial', exact=True).first).to_be_visible(timeout=10000)

    login(t, 'tablet.mur@teste.local')
    t.wait_for_url(re.compile(r'.*/terminal$'))

    a.locator('#balcao-leitura').click()
    bipar(a, 'MAT-DEMO000001')
    expect(a.get_by_text('Material incluído')).to_be_visible(timeout=10000)
    a.get_by_role('button', name='FINALIZAR SEPARAÇÃO').click()
    a.get_by_role('button', name='Finalizar', exact=True).click()

    # Solicitante confirma no tablet (foto + assinatura)
    expect(t.get_by_role('button', name='CONFIRMAR ME')).to_be_visible(timeout=15000)
    t.get_by_role('button', name='CONFIRMAR ME').click()
    t.get_by_role('button', name='Está correto, confirmar').click()
    t.wait_for_timeout(1500)
    t.get_by_role('button', name='Tirar foto').click(timeout=15000)
    t.get_by_role('button', name='Usar esta foto').click()
    canvas = t.locator('canvas')
    box = canvas.bounding_box()
    t.mouse.move(box['x'] + 30, box['y'] + box['height'] / 2)
    t.mouse.down()
    for i in range(1, 40):
        t.mouse.move(box['x'] + 30 + i * 6, box['y'] + box['height'] / 2 + (20 if i % 8 < 4 else -20))
    t.mouse.up()
    t.get_by_role('button', name='Confirmar ME', exact=True).click()
    expect(t.get_by_text('ME confirmada').first).to_be_visible(timeout=15000)

    expect(a.get_by_text('ME emergencial concluída, só para controle (sem SA e sem baixa no ERP).', exact=False)).to_be_visible(timeout=15000)
    expect(a.get_by_text('Emergencial · controle')).to_be_visible()
    a.screenshot(path=f'{OUT}/e02_balcao_concluida.png', full_page=True)
    a.get_by_role('link', name='Ver detalhes da ME').click()
    expect(a.get_by_text('ME emergencial · somente controle')).to_be_visible(timeout=10000)
    expect(a.get_by_text('Motivo: Caminhão parado na rota, fora do horário')).to_be_visible()
    me_number = a.locator('h1 .font-mono, h1 span.font-mono').first.inner_text() if a.locator('h1 .font-mono').count() else ''
    a.screenshot(path=f'{OUT}/e03_detalhe.png', full_page=True)

    # Não aparece em Pendências SA / ERP
    a.goto(f'{BASE}/pendencias-sa')
    a.wait_for_timeout(2000)
    a.get_by_role('button', name=re.compile('Aguardando baixa no ERP')).click()
    a.wait_for_timeout(1500)
    assert a.get_by_text('AF-0099').count() == 0, 'emergencial não deveria ir para pendências'
    a.screenshot(path=f'{OUT}/e04_pendencias.png', full_page=True)

    # Lista com filtro "Emergenciais"
    a.goto(f'{BASE}/movimentacoes?emergency=sim')
    expect(a.get_by_text('Emergencial · controle').first).to_be_visible(timeout=10000)
    a.screenshot(path=f'{OUT}/e05_lista_emergenciais.png', full_page=True)
    print('OK', me_number)
    browser.close()
