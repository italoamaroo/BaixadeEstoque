import os, re, sys, time
from playwright.sync_api import sync_playwright, expect

BASE = 'http://localhost:5173'
OUT = os.environ.get('E2E_OUT', 'tests/e2e/capturas')
os.makedirs(OUT, exist_ok=True)
errors = []

def attach(page, tag):
    page.on('console', lambda m: errors.append(f'[{tag}] console.{m.type}: {m.text}') if m.type == 'error' else None)
    page.on('pageerror', lambda e: errors.append(f'[{tag}] pageerror: {e}'))

def login(page, email):
    page.goto(f'{BASE}/login')
    page.get_by_label('E-mail').fill(email)
    page.get_by_label('Senha').fill('teste123')
    page.get_by_role('button', name='Entrar').click()
    page.wait_for_url(re.compile(r'.*/$'), timeout=15000)

with sync_playwright() as p:
    browser = p.chromium.launch(args=['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'])

    # ---------------- Almoxarife (celular) ----------------
    ctx = browser.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True, permissions=['camera'])
    page = ctx.new_page(); attach(page, 'almox')
    page.goto(f'{BASE}/login'); page.wait_for_timeout(800)
    page.screenshot(path=f'{OUT}/01_login.png')
    login(page, 'almox.mur@teste.local')
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/02_painel_mobile.png', full_page=True)

    page.goto(f'{BASE}/nova-saida'); page.wait_for_timeout(2500)
    page.screenshot(path=f'{OUT}/03_itens_camera.png')
    # entrada manual do QR
    page.get_by_role('button', name='Digitar código').click()
    page.get_by_label('Código do QR Code ou do material').fill('MAT-DEMO000001')
    page.get_by_role('button', name='Buscar').click()
    expect(page.get_by_text('Material identificado')).to_be_visible(timeout=10000)
    page.get_by_role('textbox', name='Quantidade solicitada', exact=True).fill('20')
    page.get_by_role('textbox', name='Quantidade atendida', exact=True).fill('18')
    page.get_by_label('Observação do item (motivo da diferença)').fill('Saldo insuficiente')
    page.screenshot(path=f'{OUT}/04_modal_item.png')
    page.get_by_role('button', name='Adicionar à ME').click()
    page.wait_for_timeout(600)
    # QR não cadastrado
    page.get_by_label('Código do QR Code ou do material').fill('NAO-EXISTE-999')
    page.get_by_role('button', name='Buscar').click()
    expect(page.get_by_text('Material não localizado').first).to_be_visible(timeout=10000)
    # inativo
    page.get_by_label('Código do QR Code ou do material').fill('MAT-DEMO000012')
    page.get_by_role('button', name='Buscar').click()
    expect(page.get_by_text('não pode ser baixado').first).to_be_visible(timeout=10000)
    page.get_by_role('button', name='Cancelar').click()
    # leitura repetida soma
    page.get_by_label('Código do QR Code ou do material').fill('MAT-DEMO000001')
    page.get_by_role('button', name='Buscar').click()
    expect(page.get_by_text('Este material já está na ME')).to_be_visible(timeout=10000)
    page.get_by_role('button', name='Adicionar à ME').click()
    page.wait_for_timeout(500)
    # pesquisa manual
    page.get_by_role('tab', name='Pesquisar').click()
    page.get_by_label('Pesquisar material').fill('filtro de óleo')
    page.get_by_role('button', name=re.compile('Filtro de óleo')).first.click()
    page.get_by_role('button', name='Adicionar à ME').click()
    page.wait_for_timeout(500)
    page.screenshot(path=f'{OUT}/05_carrinho.png', full_page=True)
    page.get_by_role('button', name=re.compile(r'^Continuar \(2 itens\)')).click()

    # dados
    page.get_by_label('Contrato').select_option(index=1)
    page.get_by_label('Setor').select_option(label='Manutenção mecânica')
    page.get_by_label('Frente de serviço / equipamento').select_option(index=4)
    page.get_by_label('Ordem de serviço').fill('DEMO-OS-24101')
    page.screenshot(path=f'{OUT}/06_dados.png', full_page=True)
    page.get_by_role('button', name='Continuar', exact=True).click()

    # requisitante
    page.get_by_label('Pesquisar funcionário requisitante').fill('José')
    page.get_by_role('button', name=re.compile('José Carlos da Silva')).click()
    page.screenshot(path=f'{OUT}/07_requisitante.png', full_page=True)
    page.get_by_role('button', name='Ir para assinatura').click()

    # assinatura vazia bloqueada
    expect(page.get_by_role('button', name='Confirmar assinatura')).to_be_disabled()
    canvas = page.locator('canvas')
    box = canvas.bounding_box()
    page.mouse.move(box['x'] + 30, box['y'] + box['height'] / 2)
    page.mouse.down()
    for i in range(1, 60):
        page.mouse.move(box['x'] + 30 + i * 5, box['y'] + box['height'] / 2 + (25 if i % 8 < 4 else -25) * (i % 4) / 3)
    page.mouse.up()
    page.screenshot(path=f'{OUT}/08_assinatura.png', full_page=True)
    page.get_by_role('button', name='Confirmar assinatura').click()

    # revisão + confirmação (duplo clique rápido)
    expect(page.get_by_role('button', name='Confirmar e gerar ME')).to_be_enabled(timeout=10000)
    page.screenshot(path=f'{OUT}/09_revisao.png', full_page=True)
    btn = page.get_by_role('button', name='Confirmar e gerar ME')
    btn.dblclick()
    expect(page.get_by_text('ME confirmada pelo servidor')).to_be_visible(timeout=20000)
    me = page.locator('p.font-mono').first.inner_text()
    print('ME gerada:', me)
    page.screenshot(path=f'{OUT}/10_sucesso.png')
    ctx.close()

    # ---------------- Equipe SA (desktop) ----------------
    ctx = browser.new_context(viewport={'width': 1366, 'height': 900})
    page = ctx.new_page(); attach(page, 'sa')
    login(page, 'sa@teste.local')
    page.goto(f'{BASE}/pendencias-sa'); page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/11_pendencias.png', full_page=True)
    page.get_by_role('button', name='Informar SA').first.click()
    page.get_by_label('Número da SA').fill('sa #1')
    page.get_by_role('button', name='Informar SA').last.click()
    expect(page.get_by_text('formato inválido')).to_be_visible()
    page.get_by_label('Número da SA').fill('SA-2026-000123')
    page.get_by_role('button', name='Informar SA').last.click()
    page.wait_for_timeout(1200)
    page.get_by_role('button', name=re.compile('SA informada')).click()
    page.wait_for_timeout(1000)
    page.get_by_role('button', name='Concluir', exact=True).first.click()
    expect(page.get_by_text('concluída.').first).to_be_visible(timeout=10000)
    page.wait_for_timeout(1200)
    ctx.close()

    # ---------------- Gestor (desktop) ----------------
    ctx = browser.new_context(viewport={'width': 1366, 'height': 900}, accept_downloads=True)
    page = ctx.new_page(); attach(page, 'gestor')
    login(page, 'gestor@teste.local')
    page.wait_for_timeout(2000)
    page.screenshot(path=f'{OUT}/12_painel_gestor.png', full_page=True)
    page.goto(f'{BASE}/movimentacoes'); page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/13_lista.png', full_page=True)
    page.get_by_role('link', name=me).click()
    page.wait_for_timeout(1500)
    page.get_by_role('button', name='Ver assinatura').first.click()
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/14_detalhe.png', full_page=True)
    page.get_by_role('button', name='Histórico e auditoria').click()
    page.wait_for_timeout(1000)
    page.screenshot(path=f'{OUT}/15_historico.png', full_page=True)
    page.emulate_media(media='print')
    page.screenshot(path=f'{OUT}/16_impressao.png', full_page=True)
    page.emulate_media(media='screen')
    # exportação
    page.goto(f'{BASE}/exportar'); page.wait_for_timeout(1500)
    with page.expect_download() as d:
        page.get_by_role('button', name='Gerar Excel').click()
    dl = d.value
    dl.save_as(f'{OUT}/{dl.suggested_filename}')
    print('Excel:', dl.suggested_filename)
    # cancelamento
    page.goto(f'{BASE}/movimentacoes'); page.wait_for_timeout(1000)
    page.get_by_role('link', name=me).click(); page.wait_for_timeout(1200)
    page.get_by_role('button', name='Cancelar ME').click()
    page.get_by_role('button', name='Cancelar ME').last.click()
    expect(page.get_by_text('mínimo 5 caracteres')).to_be_visible()
    page.get_by_label('Justificativa').fill('Teste automatizado de cancelamento')
    page.get_by_role('button', name='Cancelar ME').last.click()
    expect(page.get_by_text('ME cancelada em')).to_be_visible(timeout=10000)
    page.screenshot(path=f'{OUT}/17_cancelada.png')
    ctx.close()

    # ---------------- Admin ----------------
    ctx = browser.new_context(viewport={'width': 1366, 'height': 900})
    page = ctx.new_page(); attach(page, 'admin')
    login(page, 'admin@teste.local')
    for path, name in [('/cadastros/materiais', '18_materiais'), ('/cadastros/etiquetas?ids=', '19_etiquetas'), ('/admin/usuarios', '20_usuarios'),
                       ('/admin/perfis', '21_perfis'), ('/admin/auditoria', '22_auditoria'), ('/admin/configuracoes', '23_config'),
                       ('/cadastros/auxiliares', '24_auxiliares'), ('/cadastros/funcionarios', '25_funcionarios')]:
        page.goto(BASE + path); page.wait_for_timeout(1500)
        page.screenshot(path=f'{OUT}/{name}.png', full_page=True)
    ctx.close()
    browser.close()

print('\n'.join(errors) if errors else 'Sem erros no console.')
