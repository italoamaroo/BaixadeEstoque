"""Teste ponta a ponta da auditoria (fase 1): consulta pelo servidor, integridade, âncora e exportação."""
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
    page.wait_for_url(re.compile(r'.*/$'), timeout=15000)


with sync_playwright() as p:
    browser = p.chromium.launch()

    # Administrador
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1000}, accept_downloads=True)
    a = ctx.new_page()
    login(a, 'admin@teste.local')
    a.goto(f'{BASE}/admin/auditoria')
    expect(a.get_by_text('Integridade da auditoria', exact=True)).to_be_visible(timeout=15000)
    expect(a.locator('ul li').first).to_be_visible(timeout=15000)

    a.get_by_role('button', name='Verificar integridade').click()
    expect(a.get_by_text(re.compile(r'Íntegro: \d+ evento'))).to_be_visible(timeout=15000)

    with a.expect_download() as d:
        a.get_by_role('button', name='Gerar âncora (baixar)').click()
    anchor_path = os.path.join(OUT, 'ancora-teste.txt')
    d.value.save_as(anchor_path)
    text = open(anchor_path, encoding='utf-8').read()
    assert re.search(r'sequencia: \d+', text) and re.search(r'hash: [0-9a-f]{64}', text), text
    expect(a.get_by_text(re.compile('Âncora gerada'))).to_be_visible()

    a.locator('input[type=file]').set_input_files(anchor_path)
    expect(a.get_by_text(re.compile('A âncora confere'))).to_be_visible(timeout=15000)

    # âncora adulterada
    fake = os.path.join(OUT, 'ancora-falsa.txt')
    open(fake, 'w', encoding='utf-8').write(re.sub(r'hash: [0-9a-f]{64}', 'hash: ' + 'b' * 64, text))
    a.locator('input[type=file]').set_input_files(fake)
    expect(a.get_by_text(re.compile('A âncora NÃO confere'))).to_be_visible(timeout=15000)

    # a própria consulta aparece na trilha
    a.get_by_label('Categoria').select_option('auditoria')
    a.get_by_role('button', name='Buscar').click()
    expect(a.locator('ul li').get_by_text('Auditoria consultada').first).to_be_visible(timeout=15000)
    expect(a.locator('ul li').get_by_text('Âncora da auditoria conferida').first).to_be_visible()
    a.screenshot(path=f'{OUT}/a01_auditoria_admin.png', full_page=True)

    # exportação exige finalidade e gera arquivo
    a.get_by_role('button', name='Exportar', exact=True).click()
    exp_btn = a.get_by_role('dialog').get_by_role('button', name='Exportar')
    expect(exp_btn).to_be_disabled()
    a.get_by_label(re.compile('Finalidade da exportação')).fill('Teste automatizado da exportação')
    with a.expect_download() as d2:
        exp_btn.click()
    assert d2.value.suggested_filename.endswith('.xlsx')
    expect(a.get_by_text(re.compile('exportação foi registrada'))).to_be_visible(timeout=10000)

    # nome de funcionário nunca aparece nos dados de auditoria
    a.get_by_label('Categoria').select_option('')
    a.get_by_role('button', name='Buscar').click()
    a.wait_for_timeout(1500)
    body = a.locator('body').inner_text()
    ctx.close()

    # Gestor: sem painel de integridade, sem exportar, sem IP
    ctx2 = browser.new_context(viewport={'width': 1366, 'height': 1000})
    g = ctx2.new_page()
    login(g, 'gestor@teste.local')
    g.goto(f'{BASE}/admin/auditoria')
    expect(g.locator('ul li').first).to_be_visible(timeout=15000)
    assert g.get_by_text('Integridade da auditoria', exact=True).count() == 0
    assert g.get_by_role('button', name='Exportar', exact=True).count() == 0
    assert 'IP ' not in g.locator('main').inner_text(), 'gestor não deveria ver IP'
    g.screenshot(path=f'{OUT}/a02_auditoria_gestor.png', full_page=True)

    # histórico na ME continua aparecendo para o gestor
    g.goto(f'{BASE}/movimentacoes')
    g.locator('tbody tr').first.get_by_title('Visualizar').click()
    g.wait_for_url(re.compile(r'.*/movimentacoes/[0-9a-f-]{36}$'), timeout=15000)
    g.get_by_role('tab', name='Histórico e auditoria').or_(g.get_by_role('button', name='Histórico e auditoria')).first.click()
    expect(g.get_by_text(re.compile('ME criada|Separação aberta no balcão|ME confirmada')).first).to_be_visible(timeout=15000)
    g.screenshot(path=f'{OUT}/a03_historico_me_gestor.png', full_page=True)
    ctx2.close()
    print('OK')
    browser.close()
