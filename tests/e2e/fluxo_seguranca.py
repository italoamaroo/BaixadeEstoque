"""Teste ponta a ponta da fase 2: falha de login, login/saída, alertas, retenção, retenção legal e descarte."""
import os
import re
from playwright.sync_api import sync_playwright, expect

BASE = os.environ.get('E2E_BASE', 'http://localhost:5173')
OUT = os.environ.get('E2E_OUT', 'tests/e2e/capturas')
os.makedirs(OUT, exist_ok=True)


def login(page, email, password='teste123', ok=True):
    page.goto(f'{BASE}/login')
    page.get_by_label('E-mail').fill(email)
    page.get_by_label('Senha').fill(password)
    page.get_by_role('button', name='Entrar').click()
    if ok:
        page.wait_for_url(re.compile(r'.*/$'), timeout=15000)


with sync_playwright() as p:
    browser = p.chromium.launch()

    # 5 falhas de login seguidas -> alerta
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1000})
    f = ctx.new_page()
    for _ in range(5):
        login(f, 'almox.mur@teste.local', 'senha-errada', ok=False)
        expect(f.get_by_text(re.compile('E-mail ou senha incorretos'))).to_be_visible(timeout=10000)
    ctx.close()

    # Administrador: entra, vê o alerta, trata, configura retenção e retenção legal
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1000})
    a = ctx.new_page()
    login(a, 'admin@teste.local')
    a.get_by_role('link', name='Segurança').click()
    expect(a.get_by_text(re.compile('Muitas falhas de login|falhas de login', re.I)).first).to_be_visible(timeout=15000)
    expect(a.get_by_text(re.compile('Desativado'))).to_be_visible()

    a.get_by_role('button', name='Rodar verificações agora').click()
    expect(a.get_by_text(re.compile('Verificações concluídas: integridade ok'))).to_be_visible(timeout=15000)
    a.screenshot(path=f'{OUT}/s01_seguranca_alertas.png', full_page=True)

    item = a.locator('li').filter(has_text=re.compile('falhas de login', re.I)).first
    item.get_by_role('button', name='Tratar').click()
    dlg = a.get_by_role('dialog')
    dlg.get_by_label('Situação').select_option('encerrado')
    expect(dlg.get_by_role('button', name='Salvar')).to_be_disabled()
    dlg.get_by_label(re.compile('Tratamento')).fill('Usuário confirmou que errou a senha')
    dlg.get_by_role('button', name='Salvar').click()
    expect(a.get_by_text('Alerta atualizado.')).to_be_visible(timeout=10000)
    expect(a.get_by_text(re.compile('Usuário confirmou que errou a senha'))).to_be_visible()

    # Retenção: altera (vira proposta) e aprova
    a.get_by_role('tab', name='Retenção', exact=True).click()
    row = a.locator('tr').filter(has_text='Autenticação')
    row.get_by_role('button', name='Alterar').click()
    dlg = a.get_by_role('dialog')
    dlg.get_by_label('Prazo (dias)').fill('180')
    dlg.get_by_label(re.compile('Fundamento')).fill('Validado com o jurídico em teste automatizado')
    dlg.get_by_role('button', name='Salvar como proposta').click()
    expect(a.get_by_text(re.compile('Prazo salvo como proposta'))).to_be_visible(timeout=10000)
    a.locator('tr').filter(has_text='Autenticação').get_by_role('button', name='Aprovar').click()
    expect(a.locator('tr').filter(has_text='Autenticação').get_by_text(re.compile('Aprovada'))).to_be_visible(timeout=10000)
    a.screenshot(path=f'{OUT}/s02_seguranca_retencao.png', full_page=True)

    # Retenção legal
    a.get_by_role('tab', name='Retenção legal').click()
    a.get_by_role('button', name='Abrir retenção legal').click()
    dlg = a.get_by_role('dialog')
    dlg.get_by_label('Motivo').fill('Investigação de teste automatizado')
    dlg.get_by_role('button', name='Abrir').click()
    expect(a.get_by_text('(ativa)')).to_be_visible(timeout=10000)

    # Descarte: com um só administrador, fica bloqueado e explicado
    a.get_by_role('tab', name='Descarte').click()
    expect(a.get_by_text('Só existe um administrador ativo')).to_be_visible()
    expect(a.get_by_role('button', name='Pedir descarte')).to_be_disabled()
    a.screenshot(path=f'{OUT}/s03_seguranca_descarte.png', full_page=True)

    # A trilha mostra login, falha de login (mascarada) e o tratamento
    a.goto(f'{BASE}/admin/auditoria')
    a.get_by_label('Categoria').select_option('autenticacao')
    a.get_by_role('button', name='Buscar').click()
    expect(a.locator('ul li').get_by_text('Entrada no sistema').first).to_be_visible(timeout=15000)
    expect(a.locator('ul li').get_by_text('Falha de login').first).to_be_visible()
    assert 'almox.mur@teste.local' not in a.locator('main').inner_text(), 'e-mail completo não deveria aparecer'
    a.screenshot(path=f'{OUT}/s04_auditoria_autenticacao.png', full_page=True)
    ctx.close()

    # Gestor: vê alertas sem detalhes e sem tratar; sem abas de retenção
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1000})
    g = ctx.new_page()
    login(g, 'gestor@teste.local')
    g.goto(f'{BASE}/admin/seguranca')
    expect(g.get_by_text(re.compile('Somente o administrador trata alertas'))).to_be_visible(timeout=15000)
    assert g.get_by_role('button', name='Tratar').count() == 0
    assert g.get_by_role('tab', name='Retenção', exact=True).count() == 0
    assert g.get_by_role('button', name='Rodar verificações agora').count() == 0
    g.screenshot(path=f'{OUT}/s05_seguranca_gestor.png', full_page=True)
    ctx.close()

    # Almoxarife não vê o menu nem a página
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1000})
    m = ctx.new_page()
    login(m, 'almox.mur@teste.local')
    assert m.get_by_role('link', name='Segurança').count() == 0
    m.get_by_role('button', name=re.compile('Almox Muribeca|Menu do usuário', re.I)).first.click()
    m.get_by_role('button', name='Sair').click()
    m.wait_for_url(re.compile(r'.*/login$'), timeout=15000)
    ctx.close()
    print('OK')
    browser.close()
